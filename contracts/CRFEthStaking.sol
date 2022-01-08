// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "./utils/Address.sol";
import "./utils/Ownable.sol";
import "./utils/Pausable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/SafeMath.sol";
import "./interface/IERC20.sol";

contract CRFEthStaking is Ownable, Pausable, ReentrancyGuard {

    using Address for address;
    using SafeMath for uint256;

    uint256 public constant REWARD_UNIT = 1500 * 1e15;
    uint256 private constant SHARE_UNIT = 1e12;
    uint256 private constant ETH_STAKE_UNIT = 0.1 ether;

    IERC20 private immutable _TokenContract;
    address private immutable _tokenAddress;

    uint256 private  _stakeStartBlock;
    uint256 private immutable _totalStakeBlocks;
    uint256 public stakeEndBlock;
    uint256 public claimBlock;

    mapping(address => uint256) private _stakeAmount;
    mapping(address => uint256) private _stakeBlocknum;
    mapping(address => uint256) private _unstakeBlocknum;
    mapping(address => uint256) private _untakedRewards;

    uint256 private _secondLastStakedBlock;
    uint256 private _lastStakedBlock;
    mapping(uint256 => uint256) private _blockEthShare;
    mapping(uint256 => uint256) private _blockEthAccShare;

    uint256 private _totalStakedEth;
    uint256 private _totalUsers;
    mapping(address => bool) private _users;

    mapping(uint256 => uint256) public blockTotalEth;

    event Stake(address indexed staker, uint256 blocknum, uint256 ethAmount);
    event Unstake(address indexed staker, uint256 blocknum, uint256 ethAmount, uint256 tokenAmount);
    event Claim(address indexed staker, uint256 blocknum, uint256 tokenAmount);

    constructor(
        uint256 totalStakeBlocks,
        address tokenAddress
    )
    {
        require(tokenAddress != address(0), "Zero address is not allowed");
        _totalStakeBlocks = totalStakeBlocks;
        _tokenAddress = tokenAddress;
        _TokenContract = IERC20(tokenAddress);
        _pause();
    }

    function setClaimBlock(uint256 claimBlock_) external onlyOwner {
        claimBlock = claimBlock_;
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function getTokenAddress() external view returns(address) {
        return _tokenAddress;
    }

    function getStakeAmount(address staker) external view returns(uint256) {
        return _stakeAmount[staker];
    }

    function getUntakeReward(address staker) external view returns(uint256) {
        return _untakedRewards[staker];
    }

    function start() external whenPaused onlyOwner {
        _stakeStartBlock = block.number;
        stakeEndBlock = block.number + _totalStakeBlocks;
        claimBlock = stakeEndBlock;
        _totalStakedEth = ETH_STAKE_UNIT;

        _lastStakedBlock = _stakeStartBlock;
        _blockEthShare[_lastStakedBlock] = SHARE_UNIT;
        _blockEthAccShare[_lastStakedBlock] = SHARE_UNIT;
        _unpause();
    }

    function totalUsers() external view returns(uint256) {
        return _totalUsers;
    }

    function totalEth() external view returns(uint256) {
        return _totalStakedEth;
    }

    function totalUnclaimedReward(address staker) external view returns(uint256) {
        if(_stakeAmount[staker] == 0) {
            return _untakedRewards[staker];
        } else {
            uint256 blocknum = block.number;
            if(blocknum > stakeEndBlock) {
                blocknum = stakeEndBlock;
            }
            uint256 stakedBlock = _stakeBlocknum[staker];
            uint256 accShare = 0;
            uint256 blockEthShare;
            if(blockTotalEth[_secondLastStakedBlock] == 0) {
                blockEthShare = SHARE_UNIT.mul(ETH_STAKE_UNIT).div(_totalStakedEth);
            } else {
                blockEthShare = SHARE_UNIT.mul(ETH_STAKE_UNIT).div(blockTotalEth[_secondLastStakedBlock]);
            }
            if(blocknum == _lastStakedBlock) {
                accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                    _blockEthShare[_secondLastStakedBlock] * (blocknum > _secondLastStakedBlock ? blocknum - _secondLastStakedBlock - 1 : 0)
                );
            } else {
                accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                    _blockEthShare[_secondLastStakedBlock] * (_lastStakedBlock - _secondLastStakedBlock - 1)
                );
                blockEthShare = SHARE_UNIT.mul(ETH_STAKE_UNIT).div(_totalStakedEth);
                accShare = accShare + blockEthShare * (blocknum - _lastStakedBlock);
            }
            if(_blockEthAccShare[stakedBlock] == 0) {
                accShare = blockEthShare * (blocknum > _lastStakedBlock ? blocknum - _lastStakedBlock - 1 : 0);
            } else {
                accShare = accShare.sub(_blockEthAccShare[stakedBlock].sub(_blockEthShare[stakedBlock]));
            }
            return _untakedRewards[staker] + _stakeAmount[staker].mul(accShare).mul(REWARD_UNIT).div(SHARE_UNIT).div(ETH_STAKE_UNIT);
        }
    }

    function _calcRewards(address staker, uint256 accShare) internal view returns(uint256) {
        uint256 amount = _stakeAmount[staker];
        uint256 stakedBlock = _stakeBlocknum[staker];
        uint256 share = accShare - (_blockEthAccShare[stakedBlock] - _blockEthShare[stakedBlock]);

        uint256 reward = amount.mul(share).mul(REWARD_UNIT).div(SHARE_UNIT).div(ETH_STAKE_UNIT);
        return reward;
    }

    function stake() external payable nonReentrant whenNotPaused {
        address staker = _msgSender();
        uint256 stakedWei = msg.value;

        uint256 blocknum = block.number;
        require(blocknum >=  _stakeStartBlock && blocknum < stakeEndBlock, "Not right time to stake.");
        require(tx.origin == msg.sender, "Staker can only be EOA.");
        require(_stakeBlocknum[staker] == 0 || _stakeBlocknum[staker] != blocknum, "Staking more than once in one block.");

        if(blocknum == _lastStakedBlock) {
            if(_stakeAmount[staker] > 0) {
                uint256 accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                    _blockEthShare[_secondLastStakedBlock].mul(_lastStakedBlock - _secondLastStakedBlock - 1)
                );
                uint256 reward = _calcRewards(staker, accShare);
                _untakedRewards[staker] += reward;
            }
        } else {
            uint256 accShare;
            uint256 blockEthShare;
            if(_lastStakedBlock != 0) {
                
                blockEthShare = SHARE_UNIT.mul(ETH_STAKE_UNIT).div(_totalStakedEth);
                _blockEthShare[_lastStakedBlock] = blockEthShare;
            
                accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                    _blockEthShare[_secondLastStakedBlock].mul(_lastStakedBlock - _secondLastStakedBlock - 1)
                ).add(blockEthShare);
                _blockEthAccShare[_lastStakedBlock] = accShare;

                blockTotalEth[_lastStakedBlock] = _totalStakedEth;
            }
            _secondLastStakedBlock = _lastStakedBlock;
            _lastStakedBlock = blocknum;

            if(_stakeAmount[staker] > 0) {
                accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                    _blockEthShare[_secondLastStakedBlock].mul(_lastStakedBlock - _secondLastStakedBlock - 1));
                uint256 reward = _calcRewards(staker, accShare);
                
                _untakedRewards[staker] += reward;
            }
        }

        _stakeAmount[staker] = _stakeAmount[staker].add(stakedWei);
        _stakeBlocknum[staker] = blocknum;

        _totalStakedEth += stakedWei;
        if (!_users[staker]) {
            _users[staker] = true;
            _totalUsers += 1;
        }

        emit Stake(msg.sender, block.number, stakedWei);
    }

    function unstake(uint256 unstakedWei) external nonReentrant whenNotPaused {
        address staker = _msgSender();
        uint256 blocknum = block.number;

        require(_stakeAmount[staker] > 0, "Not staked.");
        require(tx.origin == msg.sender, "Staker can only be EOA.");
        require(_stakeAmount[staker] >= unstakedWei, "Not sufficent stake amount.");
        require(_unstakeBlocknum[staker] == 0 || _unstakeBlocknum[staker] != blocknum, "Unstaking more than once in one block.");

        uint unstakeBlockNumber = blocknum;

        if (blocknum >= stakeEndBlock) {
            blocknum = stakeEndBlock;
            unstakeBlockNumber = stakeEndBlock;
            unstakedWei = _stakeAmount[staker];
        }

        uint256 accShare;
        if(blocknum == _lastStakedBlock) {
            accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                _blockEthShare[_secondLastStakedBlock].mul(blocknum - _secondLastStakedBlock - 1)
            );
        } else {
            uint256 blockEthShare = SHARE_UNIT.mul(ETH_STAKE_UNIT).div(_totalStakedEth);
            _blockEthShare[_lastStakedBlock] = blockEthShare;
            
            accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                _blockEthShare[_secondLastStakedBlock].mul(_lastStakedBlock - _secondLastStakedBlock - 1)
            ).add(blockEthShare);
            _blockEthAccShare[_lastStakedBlock] = accShare;

            _secondLastStakedBlock = _lastStakedBlock;
            _lastStakedBlock = blocknum;

            accShare = _blockEthAccShare[_secondLastStakedBlock].add(
                _blockEthShare[_secondLastStakedBlock].mul(_lastStakedBlock - _secondLastStakedBlock - 1));
        }

        uint256 reward = _calcRewards(staker, accShare);
        uint256 totalReward = _untakedRewards[staker].add(reward);
        _untakedRewards[staker] = totalReward;
        
        if(unstakedWei < _stakeAmount[staker]) {
            _stakeBlocknum[staker] = unstakeBlockNumber;
        } else {
            _stakeBlocknum[staker] = 0;
        }
        _stakeAmount[staker] -= unstakedWei;
        _totalStakedEth -= unstakedWei;
        _unstakeBlocknum[staker] = blocknum;

        (bool success, ) = staker.call{value: unstakedWei}("");
        require(success, "Transfer failed.");

        emit Unstake(staker, block.number, unstakedWei, totalReward);
    }

    function claim() external nonReentrant whenNotPaused {
        address staker = _msgSender();
        uint256 reward = _untakedRewards[staker];
        require(tx.origin == msg.sender, "Staker can only be EOA.");
        require(reward > 0, "None staked.");
        require(block.number > claimBlock, "Can not claim yet.");
        _untakedRewards[staker] = 0;
        require(_TokenContract.transfer(staker, reward), "Transfer token failed.");

        emit Claim(staker, block.number, reward);
    }

    function returnTokens(address reciever, uint256 amount) external onlyOwner {
        _TokenContract.transfer(reciever, amount);
    }
}

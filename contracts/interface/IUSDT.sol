// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

interface IUSDT {
  function basisPointsRate() external returns(uint);
  function maximumFee() external returns(uint);
  function transfer(address _to, uint _value) external;
  function transferFrom(address _from, address _to, uint _value) external;
}
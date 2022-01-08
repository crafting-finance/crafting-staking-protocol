// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface INFT {
  function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) external;
  function transferFrom(address _from, address _to, uint256 _tokenId) external;
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IWBNB {
  function deposit() external payable;

  function withdraw(uint256 wad) external;

  function balanceOf(address owner) external view returns (uint256);

  function transfer(address to, uint256 value) external returns (bool);

  function approve(address spender, uint256 value) external returns (bool);

  function transferFrom(address from, address to, uint256 value) external returns (bool);
}

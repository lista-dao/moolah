// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBuyBack {
  function addTokenInWhitelist(address token) external;
  function tokenInWhitelist(address token) external view returns (bool);
}

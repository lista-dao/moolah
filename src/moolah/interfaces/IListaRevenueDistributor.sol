// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IListaRevenueDistributor {
  function addTokensToWhitelist(address[] memory tokens) external;
  function tokenWhitelist(address token) external view returns (bool);
}

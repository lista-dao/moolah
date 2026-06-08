// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IListaRevenueDistributor } from "moolah/interfaces/IListaRevenueDistributor.sol";

contract MockListaRevenueDistributor is IListaRevenueDistributor {
  mapping(address => bool) public tokenWhitelist;

  function addTokensToWhitelist(address[] memory tokens) external {
    for (uint256 i = 0; i < tokens.length; i++) {
      tokenWhitelist[tokens[i]] = true;
    }
  }
}

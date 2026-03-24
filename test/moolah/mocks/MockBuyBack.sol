// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IBuyBack } from "moolah/interfaces/IBuyBack.sol";

contract MockBuyBack is IBuyBack {
  mapping(address => bool) public tokenInWhitelist;
  function addTokenInWhitelist(address token) external {
    tokenInWhitelist[token] = true;
  }
}

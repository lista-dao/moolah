// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IListaAutoBuyBack } from "moolah/interfaces/IListaAutoBuyBack.sol";

contract MockListaAutoBuyBack is IListaAutoBuyBack {
  mapping(address => bool) public tokenWhitelist;

  function setTokenWhitelist(address token, bool status) external {
    tokenWhitelist[token] = status;
  }
}

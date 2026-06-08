// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract MockLiquidator {
  mapping(address => bool) public tokenWhitelist;
  mapping(bytes32 => bool) public marketWhitelist;
  mapping(address => bool) public smartProviders;

  function setTokenWhitelist(address token, bool status) external {
    tokenWhitelist[token] = status;
  }

  function setMarketWhitelist(bytes32 id, bool status) external {
    marketWhitelist[id] = status;
  }

  function batchSetSmartProviders(address[] calldata providers, bool status) external {
    for (uint256 i = 0; i < providers.length; i++) {
      smartProviders[providers[i]] = status;
    }
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOracle, TokenConfig } from "../interfaces/IOracle.sol";

contract OracleMock is IOracle {
  mapping(address => uint256) public price;

  function peek(address asset) external view returns (uint256) {
    return price[asset];
  }

  function setPrice(address asset, uint256 newPrice) external {
    price[asset] = newPrice;
  }

  function getTokenConfig(address asset) external view override returns (TokenConfig memory) {
    return
      TokenConfig({
        asset: asset,
        oracles: [address(this), address(this), address(this)],
        enableFlagsForOracles: [true, true, true],
        timeDeltaTolerance: 0
      });
  }
}

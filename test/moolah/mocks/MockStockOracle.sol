// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";

/// @dev Stands in for {StockOracle}: prices tokens like OracleMock, plus the public `stockSwitch`
///      getter {MarketFactory} staticcalls to detect a market-hours gated market.
contract MockStockOracle is IOracle {
  address public stockSwitch;
  mapping(address => uint256) public price;

  constructor(address stockSwitch_) {
    stockSwitch = stockSwitch_;
  }

  function setStockSwitch(address stockSwitch_) external {
    stockSwitch = stockSwitch_;
  }

  function setPrice(address asset, uint256 newPrice) external {
    price[asset] = newPrice;
  }

  function peek(address asset) external view returns (uint256) {
    return price[asset];
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

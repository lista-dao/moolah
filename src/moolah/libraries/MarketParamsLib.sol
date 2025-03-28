// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id, MarketParams } from "../interfaces/IMoolah.sol";

/// @title MarketParamsLib
/// @author Lista DAO
/// @notice Library to convert a market to its id.
library MarketParamsLib {
  /// @notice The length of the data used to compute the id of a market.
  /// @dev The length is 5 * 32 because `MarketParams` has 5 variables of 32 bytes each.
  uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

  /// @notice Returns the id of the market `marketParams`.
  function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
    assembly ("memory-safe") {
      marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
    }
  }
}

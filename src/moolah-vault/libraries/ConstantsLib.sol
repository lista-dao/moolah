// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ConstantsLib
/// @author Lista DAO
/// @notice Library exposing constants.
library ConstantsLib {
  /// @dev The maximum delay of a timelock.
  uint256 internal constant MAX_TIMELOCK = 2 weeks;

  /// @dev The minimum delay of a timelock.
  uint256 internal constant MIN_TIMELOCK = 1 days;

  /// @dev The maximum number of markets in the supply/withdraw queue.
  /// @dev Capped at 600 so a full-length setSupplyQueue (one cold SSTORE plus a validation SLOAD
  /// per element, ~24.9k gas) stays under the BEP-652 per-transaction gas limit (16,777,216).
  uint256 internal constant MAX_QUEUE_LENGTH = 600;

  /// @dev The maximum fee the vault can have (50%).
  uint256 internal constant MAX_FEE = 0.5e18;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ConstantsLib
/// @author Lista DAO
/// @notice Library exposing constants.
library ConstantsLib {
  /// @dev The maximum delay of a timelock.
  uint256 internal constant MAX_TIMELOCK = 2 weeks;

  /// @dev The minimum delay of a timelock.
  uint256 internal constant MIN_TIMELOCK = 1 days;

  /// @dev The maximum number of markets in the supply/withdraw queue.
  uint256 internal constant MAX_QUEUE_LENGTH = 30;

  /// @dev The maximum fee the vault can have (50%).
  uint256 internal constant MAX_FEE = 0.5e18;
}

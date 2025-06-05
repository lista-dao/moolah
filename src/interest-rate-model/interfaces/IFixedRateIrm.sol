// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IIrm } from "moolah/interfaces/IIrm.sol";
import { Id } from "moolah/interfaces/IMoolah.sol";

/// @title IFixedRateIrm
interface IFixedRateIrm is IIrm {
  /* EVENTS */

  /// @notice Emitted when a borrow rate is set.
  event SetBorrowRate(Id indexed id, int256 newBorrowRate);

  /* EXTERNAL */

  /// @notice Max settable borrow rate (800%).
  function MAX_BORROW_RATE() external returns (int256);

  /// @notice Fixed borrow rates.
  function borrowRateStored(Id id) external returns (int256);

  /// @notice Sets the borrow rate for a market.
  /// @dev A rate can only be set or updated by manager.
  /// @dev Reverts on not set rate, so the rate has to be set before the market creation.
  /// @dev As interest are rounded down in Moolah, for markets with a low total borrow, setting a rate too low could
  /// prevent interest from accruing if interactions are frequent.
  function setBorrowRate(Id id, int256 newBorrowRate) external;
}

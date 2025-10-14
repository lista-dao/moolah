// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IIrm } from "moolah/interfaces/IIrm.sol";
import { Id } from "moolah/interfaces/IMoolah.sol";

/// @title IInterestRateModel
/// @author Lista DAO
/// @notice Interface exposed by the InterestRateModel.
interface IInterestRateModel is IIrm {
  /// @notice Address of Moolah.
  function MOOLAH() external view returns (address);

  /// @notice Rate at target utilization.
  /// @dev Tells the height of the curve.
  function rateAtTarget(Id id) external view returns (int256);

  /// @notice Rate cap for the given market.
  function rateCap(Id id) external view returns (uint256);

  /// @notice Minimum borrow rate for the given market.
  function rateFloor(Id id) external view returns (uint256);

  /// @notice Minimum borrow rate cap for all markets.
  function minCap() external view returns (uint256);

  /// @notice Updates the borrow rate cap for a market.
  function updateRateCap(Id id, uint256 newRateCap) external;

  /// @notice Updates the minimum borrow rate cap for all markets.
  function updateMinCap(uint256 newMinCap) external;
}

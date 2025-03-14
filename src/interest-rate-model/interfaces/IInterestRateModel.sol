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
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracle
/// @author Lista Dao
/// @notice Interface that oracles used by Lista Dao must implement.
/// @dev It is the user's responsibility to select markets with safe oracles.
interface IOracle {
  function peek(address asset) external view returns (uint256);
}

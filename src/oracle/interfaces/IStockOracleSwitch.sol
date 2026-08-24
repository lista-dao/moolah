// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IStockOracleSwitch
/// @notice View + config surface of {StockOracleSwitch} used by its consumers ({StockOracle} for
///         market-hours gating, {MarketFactory} for registering a bStock collateral at market creation).
interface IStockOracleSwitch {
  /// @notice Whether `token` is currently enabled (tradable). Unregistered tokens are passthrough (always true).
  function isEnabled(address token) external view returns (bool);

  /// @notice Whether `token` is a managed stock, i.e. subject to market-hours gating.
  function registered(address token) external view returns (bool);

  /// @notice Register / un-register a managed stock. Requires MANAGER on the switch.
  /// @dev Reverts (AlreadySet) when the token is already in the requested state.
  function setStock(address token, bool isStock) external;
}

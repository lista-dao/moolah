// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal view/withdraw surface of a registered liquidation contract that the vault relies on.
///      Every liquidator (Liquidator / BrokerLiquidator / V3Liquidator) exposes these with the exact
///      same selectors, so the vault can `collect*` from any of them uniformly (funds land on the
///      vault via `msg.sender` semantics).
interface ILiquidatorWithdraw {
  function withdrawERC20(address token, uint256 amount) external;
  function withdrawETH(uint256 amount) external;
}

interface ILiquidationVault {
  /// @notice Registered liquidators pull the exact shortfall inside their onMoolahLiquidate callback.
  ///         Only transfers to msg.sender; ERC20 only (the repayment leg is always an ERC20).
  /// @dev reverts when: caller not in the `liquidators` registry / paused / balance insufficient.
  function provideFund(address token, uint256 amount) external;

  /// @notice Collect ERC20 from a registered liquidator into the vault (calls its withdrawERC20).
  function collectERC20(address liquidator, address token, uint256 amount) external;

  /// @notice Collect native BNB from a registered liquidator into the vault (calls its withdrawETH).
  function collectETH(address liquidator, uint256 amount) external;

  /// @notice Whether an address is a registered liquidator (provideFund allow-list + collect* target).
  function liquidators(address liquidator) external view returns (bool);

  event FundProvided(address indexed liquidator, address indexed token, uint256 amount);
  event FundCollected(address indexed liquidator, address indexed token, uint256 amount);
  event LiquidatorSet(address indexed liquidator, bool registered);
}

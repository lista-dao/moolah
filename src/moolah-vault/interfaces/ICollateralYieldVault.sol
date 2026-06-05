// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ICollateralYieldVault
/// @author Lista DAO
/// @notice Vault-specific entrypoint used by the RewardHarvester to inject launchpool rewards.
interface ICollateralYieldVault {
  /// @notice Stake injected BNB (`msg.value`) to slisBNB, supply it as collateral, and raise the share price (BOT-only).
  function increaseVaultAssets() external payable;
}

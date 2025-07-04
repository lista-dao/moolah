// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "moolah/interfaces/IMoolah.sol";

import { PendingAddress } from "./PendingLib.sol";

/// @title EventsLib
/// @author Lista DAO
/// @notice Library exposing events.
library EventsLib {
  /// @notice Emitted when a pending `newTimelock` is submitted.
  event SubmitTimelock(uint256 newTimelock);

  /// @notice Emitted when `timelock` is set to `newTimelock`.
  event SetTimelock(address indexed caller, uint256 newTimelock);

  /// @notice Emitted when `skimRecipient` is set to `newSkimRecipient`.
  event SetSkimRecipient(address indexed newSkimRecipient);

  /// @notice Emitted `fee` is set to `newFee`.
  event SetFee(address indexed caller, uint256 newFee);

  /// @notice Emitted when a new `newFeeRecipient` is set.
  event SetFeeRecipient(address indexed newFeeRecipient);

  /// @notice Emitted when a pending `newGuardian` is submitted.
  event SubmitGuardian(address indexed newGuardian);

  event AddWhiteList(address indexed account);

  event RemoveWhiteList(address indexed account);

  /// @notice Emitted when `guardian` is set to `newGuardian`.
  event SetGuardian(address indexed caller, address indexed guardian);

  /// @notice Emitted when a pending `cap` is submitted for market identified by `id`.
  event SubmitCap(address indexed caller, Id indexed id, uint256 cap);

  /// @notice Emitted when a new `cap` is set for market identified by `id`.
  event SetCap(address indexed caller, Id indexed id, uint256 cap);

  /// @notice Emitted when the vault's last total assets is updated to `updatedTotalAssets`.
  event UpdateLastTotalAssets(uint256 updatedTotalAssets);

  /// @notice Emitted when the market identified by `id` is submitted for removal.
  event SubmitMarketRemoval(address indexed caller, Id indexed id);

  /// @notice Emitted when `curator` is set to `newCurator`.
  event SetCurator(address indexed newCurator);

  /// @notice Emitted when an `allocator` is set to `isAllocator`.
  event SetIsAllocator(address indexed allocator, bool isAllocator);

  /// @notice Emitted when a `pendingTimelock` is revoked.
  event RevokePendingTimelock(address indexed caller);

  /// @notice Emitted when a `pendingCap` for the market identified by `id` is revoked.
  event RevokePendingCap(address indexed caller, Id indexed id);

  /// @notice Emitted when a `pendingGuardian` is revoked.
  event RevokePendingGuardian(address indexed caller);

  /// @notice Emitted when a pending market removal is revoked.
  event RevokePendingMarketRemoval(address indexed caller, Id indexed id);

  /// @notice Emitted when the `supplyQueue` is set to `newSupplyQueue`.
  event SetSupplyQueue(address indexed caller, Id[] newSupplyQueue);

  /// @notice Emitted when the `withdrawQueue` is set to `newWithdrawQueue`.
  event SetWithdrawQueue(address indexed caller, Id[] newWithdrawQueue);

  /// @notice Emitted when a reallocation supplies assets to the market identified by `id`.
  /// @param id The id of the market.
  /// @param suppliedAssets The amount of assets supplied to the market.
  /// @param suppliedShares The amount of shares minted.
  event ReallocateSupply(address indexed caller, Id indexed id, uint256 suppliedAssets, uint256 suppliedShares);

  /// @notice Emitted when a reallocation withdraws assets from the market identified by `id`.
  /// @param id The id of the market.
  /// @param withdrawnAssets The amount of assets withdrawn from the market.
  /// @param withdrawnShares The amount of shares burned.
  event ReallocateWithdraw(address indexed caller, Id indexed id, uint256 withdrawnAssets, uint256 withdrawnShares);

  /// @notice Emitted when interest are accrued.
  /// @param newTotalAssets The assets of the vault after accruing the interest but before the interaction.
  /// @param feeShares The shares minted to the fee recipient.
  event AccrueInterest(uint256 newTotalAssets, uint256 feeShares);

  /// @notice Emitted when an `amount` of `token` is transferred to the skim recipient by `caller`.
  event Skim(address indexed caller, address indexed token, uint256 amount);

  /// @notice Emitted when a `provider` is set to Vault.
  event InitProvider(address indexed provider);

  /// @notice Emitted when a new MoolahVault vault is created.
  /// @param moolahVault The address of the MoolahVault.
  /// @param implementation The implementation of the MoolahVault.
  /// @param managerTimeLock The manager timeLock contract of the MoolahVault.
  /// @param curatorTimeLock The curator timeLock contract of the MoolahVault.
  /// @param timeLockDelay The delay of the timeLock.
  /// @param caller The caller of the function.
  /// @param manager The initial manager of the MoolahVault vault.
  /// @param curator The initial curator of the MoolahVault vault.
  /// @param guardian The initial guardian of the MoolahVault vault.
  /// @param asset The address of the underlying asset.
  /// @param name The name of the MoolahVault vault.
  /// @param symbol The symbol of the MoolahVault vault.
  event CreateMoolahVault(
    address indexed moolahVault,
    address implementation,
    address managerTimeLock,
    address curatorTimeLock,
    uint256 timeLockDelay,
    address indexed caller,
    address manager,
    address curator,
    address guardian,
    address indexed asset,
    string name,
    string symbol
  );

  /// @notice Emitted when the vault admin is set to `vaultAdmin`.
  event SetVaultAdmin(address vaultAdmin);
}

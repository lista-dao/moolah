// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMoolahVault, IMoolah, MarketAllocation, Id, MarketParams } from "moolah-vault/interfaces/IMoolahVault.sol";

/// @dev Max settable flow cap, such that caps can always be stored on 128 bits.
/// @dev The actual max possible flow cap is type(uint128).max-1.
/// @dev Equals to 170141183460469231731687303715884105727;
uint128 constant MAX_SETTABLE_FLOW_CAP = type(uint128).max / 2;

struct FlowCaps {
  /// @notice The maximum allowed inflow in a market.
  uint128 maxIn;
  /// @notice The maximum allowed outflow in a market.
  uint128 maxOut;
}

struct FlowCapsConfig {
  /// @notice Market for which to change flow caps.
  Id id;
  /// @notice New flow caps for this market.
  FlowCaps caps;
}

struct Withdrawal {
  /// @notice The market from which to withdraw.
  MarketParams marketParams;
  /// @notice The amount to withdraw.
  uint128 amount;
}

/// @dev This interface is used for factorizing IVaultAllocatorStaticTyping and IVaultAllocator.
/// @dev Consider using the IVaultAllocator interface instead of this one.
interface IVaultAllocatorBase {
  /// @notice The Moolah` contract.
  function MOOLAH() external view returns (IMoolah);

  /// @notice The admin for a given vault.
  function admin(address vault) external view returns (address);

  /// @notice The current ETH fee for a given vault.
  function fee(address vault) external view returns (uint256);

  /// @notice The accrued ETH fee for a given vault.
  function accruedFee(address vault) external view returns (uint256);

  /// @notice Reallocates from a list of markets to one market.
  /// @param vault The MoolahVault vault to reallocate.
  /// @param withdrawals The markets to withdraw from,and the amounts to withdraw.
  /// @param supplyMarketParams The market receiving total withdrawn to.
  /// @dev Will call MoolahVault's `reallocate`.
  /// @dev Checks that the flow caps are respected.
  /// @dev Will revert when `withdrawals` contains a duplicate or is not sorted.
  /// @dev Will revert if `withdrawals` contains the supply market.
  /// @dev Will revert if a withdrawal amount is larger than available liquidity.
  function reallocateTo(
    address vault,
    Withdrawal[] calldata withdrawals,
    MarketParams calldata supplyMarketParams
  ) external payable;

  /// @notice Sets the admin for a given vault.
  function setAdmin(address vault, address newAdmin) external;

  /// @notice Sets the fee for a given vault.
  function setFee(address vault, uint256 newFee) external;

  /// @notice Transfers the current balance to `feeRecipient` for a given vault.
  function transferFee(address vault, address payable feeRecipient) external;

  /// @notice Sets the maximum inflow and outflow through vault allocation for some markets for a given vault.
  /// @dev Max allowed inflow/outflow is MAX_SETTABLE_FLOW_CAP.
  /// @dev Doesn't revert if it doesn't change the storage at all.
  function setFlowCaps(address vault, FlowCapsConfig[] calldata config) external;
}

/// @dev This interface is inherited by VaultAllocator so that function signatures are checked by the compiler.
/// @dev Consider using the IVaultAllocator interface instead of this one.
interface IVaultAllocatorStaticTyping is IVaultAllocatorBase {
  /// @notice Returns (maximum inflow, maximum outflow) through vault allocation of a given market for a given vault.
  function flowCaps(address vault, Id) external view returns (uint128, uint128);
}

/// @title IVaultAllocator
/// @author Lista DAO
/// @dev Use this interface for VaultAllocator to have access to all the functions with the appropriate function
/// signatures.
interface IVaultAllocator is IVaultAllocatorBase {
  /// @notice Returns the maximum inflow and maximum outflow through vault allocation of a given market for a given
  /// vault.
  function flowCaps(address vault, Id) external view returns (FlowCaps memory);
}

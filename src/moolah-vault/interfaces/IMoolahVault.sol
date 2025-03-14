// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { IMoolah, Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

import { MarketConfig, PendingUint192, PendingAddress } from "../libraries/PendingLib.sol";

struct MarketAllocation {
  /// @notice The market to allocate.
  MarketParams marketParams;
  /// @notice The amount of assets to allocate.
  uint256 assets;
}

interface IMulticall {
  function multicall(bytes[] calldata) external returns (bytes[] memory);
}

interface IOwnable {
  function transferOwnership(address) external;
  function renounceOwnership() external;
  function acceptOwnership() external;
}

/// @dev This interface is used for factorizing IMoolahVaultStaticTyping and IMoolahVault.
/// @dev Consider using the IMoolahVault interface instead of this one.
interface IMoolahVaultBase {
  /// @notice The address of the Moolah contract.
  function MOOLAH() external view returns (IMoolah);
  function DECIMALS_OFFSET() external view returns (uint8);

  /// @notice The current fee.
  function fee() external view returns (uint96);

  /// @notice The fee recipient.
  function feeRecipient() external view returns (address);

  /// @notice The skim recipient.
  function skimRecipient() external view returns (address);

  /// @dev Stores the order of markets on which liquidity is supplied upon deposit.
  /// @dev Can contain any market. A market is skipped as soon as its supply cap is reached.
  function supplyQueue(uint256) external view returns (Id);

  /// @notice Returns the length of the supply queue.
  function supplyQueueLength() external view returns (uint256);

  /// @dev Stores the order of markets from which liquidity is withdrawn upon withdrawal.
  /// @dev Always contain all non-zero cap markets as well as all markets on which the vault supplies liquidity,
  /// without duplicate.
  function withdrawQueue(uint256) external view returns (Id);

  /// @notice Returns the length of the withdraw queue.
  function withdrawQueueLength() external view returns (uint256);

  /// @notice Stores the total assets managed by this vault when the fee was last accrued.
  /// @dev May be greater than `totalAssets()` due to removal of markets with non-zero supply or socialized bad debt.
  /// This difference will decrease the fee accrued until one of the functions updating `lastTotalAssets` is
  /// triggered (deposit/mint/withdraw/redeem/setFee/setFeeRecipient).
  function lastTotalAssets() external view returns (uint256);

  /// @notice set market removal
  function setMarketRemoval(MarketParams memory) external;

  /// @notice submit cap
  function setCap(MarketParams memory, uint256) external;

  /// @notice Skims the vault `token` balance to `skimRecipient`.
  function skim(address) external;

  /// @notice Sets the `fee` to `newFee`.
  function setFee(uint256 newFee) external;

  /// @notice Sets `feeRecipient` to `newFeeRecipient`.
  function setFeeRecipient(address newFeeRecipient) external;

  /// @notice Sets `skimRecipient` to `newSkimRecipient`.
  function setSkimRecipient(address newSkimRecipient) external;

  /// @notice Sets `supplyQueue` to `newSupplyQueue`.
  /// @param newSupplyQueue is an array of enabled markets, and can contain duplicate markets, but it would only
  /// increase the cost of depositing to the vault.
  function setSupplyQueue(Id[] calldata newSupplyQueue) external;

  /// @notice Updates the withdraw queue. Some markets can be removed, but no market can be added.
  /// @notice Removing a market requires the vault to have 0 supply on it, or to have previously submitted a removal
  /// for this market (with the function `submitMarketRemoval`).
  /// @notice Warning: Anyone can supply on behalf of the vault so the call to `updateWithdrawQueue` that expects a
  /// market to be empty can be griefed by a front-run. To circumvent this, the allocator can simply bundle a
  /// reallocation that withdraws max from this market with a call to `updateWithdrawQueue`.
  /// @dev Warning: Removing a market with supply will decrease the fee accrued until one of the functions updating
  /// `lastTotalAssets` is triggered (deposit/mint/withdraw/redeem/setFee/setFeeRecipient).
  /// @dev Warning: `updateWithdrawQueue` is not idempotent. Submitting twice the same tx will change the queue twice.
  /// @param indexes The indexes of each market in the previous withdraw queue, in the new withdraw queue's order.
  function updateWithdrawQueue(uint256[] calldata indexes) external;

  /// @notice Reallocates the vault's liquidity so as to reach a given allocation of assets on each given market.
  /// @dev The behavior of the reallocation can be altered by state changes, including:
  /// - Deposits on the vault that supplies to markets that are expected to be supplied to during reallocation.
  /// - Withdrawals from the vault that withdraws from markets that are expected to be withdrawn from during
  /// reallocation.
  /// - Donations to the vault on markets that are expected to be supplied to during reallocation.
  /// - Withdrawals from markets that are expected to be withdrawn from during reallocation.
  /// @dev Sender is expected to pass `assets = type(uint256).max` with the last MarketAllocation of `allocations` to
  /// supply all the remaining withdrawn liquidity, which would ensure that `totalWithdrawn` = `totalSupplied`.
  /// @dev A supply in a reallocation step will make the reallocation revert if the amount is greater than the net
  /// amount from previous steps (i.e. total withdrawn minus total supplied).
  function reallocate(MarketAllocation[] calldata allocations) external;
}

/// @dev This interface is inherited by MoolahVault so that function signatures are checked by the compiler.
/// @dev Consider using the IMoolahVault interface instead of this one.
interface IMoolahVaultStaticTyping is IMoolahVaultBase {
  /// @notice Returns the current configuration of each market.
  function config(Id) external view returns (uint184 cap, bool enabled, uint64 removableAt);
}

/// @title IMoolahVault
/// @author Lista DAO
/// @dev Use this interface for MoolahVault to have access to all the functions with the appropriate function signatures.
interface IMoolahVault is IMoolahVaultBase, IERC4626, IERC20Permit, IOwnable, IMulticall {
  /// @notice Returns the current configuration of each market.
  function config(Id) external view returns (MarketConfig memory);

  /// @notice Returns `true` if `account` has been granted `role`.
  function hasRole(bytes32 role, address account) external view returns (bool);

  /// @dev Returns the number of accounts that have `role`.
  function getRoleMemberCount(bytes32 role) external view returns (uint256);

  /// @notice grants `role` to `account`.
  function grantRole(bytes32 role, address account) external;

  /// @notice revokes `role` from `account`.
  function revokeRole(bytes32 role, address account) external;
}

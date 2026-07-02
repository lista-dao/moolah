// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Id, MarketParams, Market, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { MarketAllocation } from "../interfaces/IMoolahVault.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { EventsLib } from "./EventsLib.sol";

/// @title MoolahVaultLib
/// @author Lista DAO
/// @notice External library for MoolahVault — reduces vault runtime bytecode below EIP-170 limit.
/// @dev Functions are `public` so the compiler emits DELEGATECALL to this separately-deployed library.
///      `address(this)` inside these functions resolves to the calling vault contract.
library MoolahVaultLib {
  using SharesMathLib for uint256;
  using UtilsLib for uint256;
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @notice Execute the reallocate loop: withdraw from over-allocated markets and supply to under-allocated ones.
  /// @param moolah       Moolah protocol instance
  /// @param allocations  Target allocations (marketParams + target assets)
  /// @param enabled      Pre-fetched config.enabled for each allocation's market
  /// @param caps         Pre-fetched config.cap for each allocation's market
  function reallocate(
    IMoolah moolah,
    MarketAllocation[] calldata allocations,
    bool[] memory enabled,
    uint184[] memory caps
  ) public {
    uint256 totalSupplied;
    uint256 totalWithdrawn;
    for (uint256 i; i < allocations.length; ++i) {
      MarketAllocation memory allocation = allocations[i];
      Id id = allocation.marketParams.id();

      // Accrue interest and get current supply balance
      moolah.accrueInterest(allocation.marketParams);
      Market memory market = moolah.market(id);
      uint256 supplyShares = moolah.position(id, address(this)).supplyShares;
      uint256 supplyAssets = supplyShares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

      uint256 withdrawn = supplyAssets.zeroFloorSub(allocation.assets);

      if (withdrawn > 0) {
        if (!enabled[i]) revert ErrorsLib.MarketNotEnabled(id);

        // Guarantees that unknown frontrunning donations can be withdrawn, in order to disable a market.
        uint256 shares;
        if (allocation.assets == 0) {
          shares = supplyShares;
          withdrawn = 0;
        }

        (uint256 withdrawnAssets, uint256 withdrawnShares) = moolah.withdraw(
          allocation.marketParams,
          withdrawn,
          shares,
          address(this),
          address(this)
        );

        emit EventsLib.ReallocateWithdraw(msg.sender, id, withdrawnAssets, withdrawnShares);

        totalWithdrawn += withdrawnAssets;
      } else {
        uint256 suppliedAssets = allocation.assets == type(uint256).max
          ? totalWithdrawn.zeroFloorSub(totalSupplied)
          : allocation.assets.zeroFloorSub(supplyAssets);

        if (suppliedAssets == 0) continue;

        uint256 supplyCap = caps[i];
        if (supplyCap == 0) revert ErrorsLib.UnauthorizedMarket(id);

        if (supplyAssets + suppliedAssets > supplyCap) revert ErrorsLib.SupplyCapExceeded(id);

        // The market's loan asset is guaranteed to be the vault's asset because it has a non-zero supply cap.
        (, uint256 suppliedShares) = moolah.supply(allocation.marketParams, suppliedAssets, 0, address(this), hex"");

        emit EventsLib.ReallocateSupply(msg.sender, id, suppliedAssets, suppliedShares);

        totalSupplied += suppliedAssets;
      }
    }

    if (totalWithdrawn != totalSupplied) revert ErrorsLib.InconsistentReallocation();
  }

  /// @notice Supply `assets` to Moolah markets following the supply queue.
  /// @param moolah  Moolah protocol instance
  /// @param queue   Supply queue market IDs (copied from vault storage)
  /// @param caps    Supply cap for each queue entry (0 = skip)
  /// @param assets  Total assets to distribute across markets
  function supplyMoolah(IMoolah moolah, Id[] memory queue, uint184[] memory caps, uint256 assets) public {
    for (uint256 i; i < queue.length; ++i) {
      Id id = queue[i];

      uint256 supplyCap = caps[i];
      if (supplyCap == 0) continue;

      MarketParams memory marketParams = moolah.idToMarketParams(id);

      moolah.accrueInterest(marketParams);

      Market memory market = moolah.market(id);
      uint256 supplyShares = moolah.position(id, address(this)).supplyShares;
      // `supplyAssets` needs to be rounded up for `toSupply` to be rounded down.
      uint256 supplyAssets = supplyShares.toAssetsUp(market.totalSupplyAssets, market.totalSupplyShares);

      uint256 toSupply = UtilsLib.min(supplyCap.zeroFloorSub(supplyAssets), assets);

      if (toSupply > 0) {
        // Using try/catch to skip markets that revert.
        try moolah.supply(marketParams, toSupply, 0, address(this), hex"") {
          assets -= toSupply;
        } catch {}
      }

      if (assets == 0) return;
    }

    if (assets != 0) revert ErrorsLib.AllCapsReached();
  }

  /// @notice Withdraw `assets` from Moolah markets following the withdraw queue.
  /// @param moolah  Moolah protocol instance
  /// @param queue   Withdraw queue market IDs (copied from vault storage)
  /// @param assets  Total assets to withdraw
  function withdrawMoolah(IMoolah moolah, Id[] memory queue, uint256 assets) public {
    for (uint256 i; i < queue.length; ++i) {
      Id id = queue[i];
      MarketParams memory marketParams = moolah.idToMarketParams(id);

      // Accrue interest and get supply balance
      moolah.accrueInterest(marketParams);
      Market memory market = moolah.market(id);
      uint256 shares = moolah.position(id, address(this)).supplyShares;
      uint256 supplyAssets = shares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

      uint256 toWithdraw = UtilsLib.min(
        _withdrawable(moolah, marketParams, market.totalSupplyAssets, market.totalBorrowAssets, supplyAssets),
        assets
      );

      if (toWithdraw > 0) {
        // Using try/catch to skip markets that revert.
        try moolah.withdraw(marketParams, toWithdraw, 0, address(this), address(this)) {
          assets -= toWithdraw;
        } catch {}
      }

      if (assets == 0) return;
    }

    if (assets != 0) revert ErrorsLib.NotEnoughLiquidity();
  }

  /// @notice Simulate a withdraw to compute the remaining unmet assets.
  /// @param moolah  Moolah protocol instance
  /// @param queue   Withdraw queue market IDs (copied from vault storage)
  /// @param assets  Total assets to simulate withdrawing
  /// @return The remaining assets that cannot be withdrawn (0 = fully satisfiable).
  function simulateWithdrawMoolah(IMoolah moolah, Id[] memory queue, uint256 assets) public view returns (uint256) {
    for (uint256 i; i < queue.length; ++i) {
      Id id = queue[i];
      MarketParams memory marketParams = moolah.idToMarketParams(id);

      uint256 supplyShares = moolah.position(id, address(this)).supplyShares;
      (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, ) = moolah
        .expectedMarketBalances(marketParams);

      assets = assets.zeroFloorSub(
        _withdrawable(
          moolah,
          marketParams,
          totalSupplyAssets,
          totalBorrowAssets,
          supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares)
        )
      );

      if (assets == 0) break;
    }

    return assets;
  }

  /// @notice Compute max depositable assets across supply queue markets.
  /// @param moolah  Moolah protocol instance
  /// @param queue   Supply queue market IDs (copied from vault storage)
  /// @param caps    Supply cap for each queue entry (0 = skip)
  function maxDeposit(
    IMoolah moolah,
    Id[] memory queue,
    uint184[] memory caps
  ) public view returns (uint256 totalSuppliable) {
    for (uint256 i; i < queue.length; ++i) {
      Id id = queue[i];

      uint256 supplyCap = caps[i];
      if (supplyCap == 0) continue;

      uint256 supplyShares = moolah.position(id, address(this)).supplyShares;
      (uint256 totalSupplyAssets, uint256 totalSupplyShares, , ) = moolah.expectedMarketBalances(
        moolah.idToMarketParams(id)
      );
      // `supplyAssets` needs to be rounded up for `totalSuppliable` to be rounded down.
      uint256 supplyAssets = supplyShares.toAssetsUp(totalSupplyAssets, totalSupplyShares);

      totalSuppliable += supplyCap.zeroFloorSub(supplyAssets);
    }
  }

  /// @notice Add or remove an account from the whitelist.
  /// @param _whiteList  Whitelist set (storage ref from vault)
  /// @param account  The account to add or remove
  /// @param enabled  True to add, false to remove
  function setWhiteList(EnumerableSet.AddressSet storage _whiteList, address account, bool enabled) public {
    if (account == address(0)) revert ErrorsLib.ZeroAddress();
    if (enabled) {
      if (_whiteList.contains(account)) revert ErrorsLib.AlreadySet();
      _whiteList.add(account);
    } else {
      if (!_whiteList.contains(account)) revert ErrorsLib.NotSet();
      _whiteList.remove(account);
    }

    emit EventsLib.SetWhiteList(account, enabled);
  }

  /// @dev Returns the withdrawable amount of assets from a market, given the market's
  /// total supply and borrow assets and the vault's assets supplied.
  function _withdrawable(
    IMoolah moolah,
    MarketParams memory marketParams,
    uint256 totalSupplyAssets,
    uint256 totalBorrowAssets,
    uint256 supplyAssets
  ) internal view returns (uint256) {
    // Inside a flashloan callback, liquidity on Moolah may be limited to the singleton's balance.
    uint256 availableLiquidity = UtilsLib.min(
      totalSupplyAssets - totalBorrowAssets,
      IERC20(marketParams.loanToken).balanceOf(address(moolah))
    );

    return UtilsLib.min(supplyAssets, availableLiquidity);
  }
}

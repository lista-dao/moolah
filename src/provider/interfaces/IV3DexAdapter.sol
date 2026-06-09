// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title IV3DexAdapter
 * @author Lista DAO
 * @notice Seam between the vault (V3Provider) / oracle (SlisBNBV3ProviderOracle) and the DEX custodian
 *         (V3DexAdapter). The adapter is the SOLE holder of the V3 NFT, the idle inventory and all
 *         NPM/pool interaction. The vault and oracle never touch NPM/pool directly — they call the
 *         adapter's `onlyProvider` write functions and read its raw-NAV/composition views (staticcall).
 *
 * @dev Conventions:
 *      - Raw NAV: all views return amounts WITHOUT any oracle haircut. The vault uses them for
 *        share accounting; the oracle applies its own haircut on top for Moolah pricing.
 *      - Token custody: before `addLiquidity` the provider transfers the input tokens to the adapter;
 *        the adapter refunds unused tokens to `refundTo` and, on `removeLiquidity`, sends the
 *        withdrawn underlying directly to `receiver` (avoids a provider→user double hop).
 *      - "amounts" are token0/token1 raw units; sqrt prices are X96.
 */
interface IV3DexAdapter {
  /* ───────────────────── pool / position accessors ────────────── */

  function TOKEN0() external view returns (address);

  function TOKEN1() external view returns (address);

  function DECIMALS0() external view returns (uint8);

  function DECIMALS1() external view returns (uint8);

  function POOL() external view returns (address);

  /// @notice The vault (V3Provider) authorized to drive this adapter.
  function provider() external view returns (address);

  function tokenId() external view returns (uint256);

  function tickLower() external view returns (int24);

  function tickUpper() external view returns (int24);

  function idleToken0() external view returns (uint256);

  function idleToken1() external view returns (uint256);

  /* ───────────────── raw-NAV / composition views ──────────────── */

  /// @notice token0/token1 represented by the whole position at `sqrtPriceX96`, INCLUDING uncollected
  ///         fees (tokensOwed) and idle inventory. Raw (no haircut). Single source of truth that both
  ///         the vault (share accounting) and oracle (Moolah pricing) read.
  function positionAmountsAt(uint160 sqrtPriceX96) external view returns (uint256 total0, uint256 total1);

  /// @notice token0/token1 for a given `liquidity` at `sqrtPriceX96` (position math only, no fees/idle).
  ///         Used by the vault's value-based share mint to value freshly added liquidity at the fair price.
  function amountsForLiquidity(
    uint128 liquidity,
    uint160 sqrtPriceX96
  ) external view returns (uint256 amount0, uint256 amount1);

  /// @notice Current liquidity of the managed position (0 if none).
  function totalLiquidity() external view returns (uint128);

  /// @notice Fair valuation price: exchange-rate-implied for slisBNB/WBNB, pool TWAP otherwise.
  function fairSqrtPriceX96() external view returns (uint160);

  /// @notice Current pool spot price (slot0).
  function spotSqrtPriceX96() external view returns (uint160);

  /// @notice Simulate adding `amount0Desired/amount1Desired` at the current spot price.
  function previewAddLiquidity(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1);

  /// @notice Simulate removing `shares/totalShares` of the position (liquidity + idle) at spot.
  function previewRemoveLiquidity(
    uint256 shares,
    uint256 totalShares
  ) external view returns (uint256 amount0, uint256 amount1);

  /* ─────────────────────── writes (onlyProvider) ──────────────── */

  /// @notice Add liquidity from tokens already transferred to the adapter; mint a fresh NFT if none
  ///         exists, otherwise increase. Unused input is refunded to `refundTo`.
  /// @return liquidityAdded Liquidity units added.
  /// @return amount0Used    token0 actually consumed by the pool.
  /// @return amount1Used    token1 actually consumed by the pool.
  function addLiquidity(
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address refundTo
  ) external returns (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used);

  /// @notice Remove the `shares/totalShares` pro-rata slice of liquidity AND idle inventory, sending
  ///         the underlying directly to `receiver` (WBNB unwrapped to native BNB). Used by the vault's
  ///         withdraw / redeemShares. No protocol value floor — the caller's minAmount0/1 is the guard
  ///         (keeps liquidation live; see finding C4).
  function removeLiquidity(
    uint256 shares,
    uint256 totalShares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);

  /// @notice Collect accrued fees and re-add them plus idle inventory as liquidity (compound).
  function collectAndCompound() external;
}

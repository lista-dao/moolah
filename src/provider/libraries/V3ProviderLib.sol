// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IOracle } from "moolah/interfaces/IOracle.sol";

import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";

/**
 * @title V3ProviderLib
 * @author Lista DAO
 * @notice Deposit-quoting and USD-valuation math for {V3Provider}, carved out as an external library so
 *         the vault runtime stays under EIP-170. Linked and DELEGATECALL-ed, like {V3PositionLib}.
 * @dev    The vault's immutables (adapter, tokens, decimals) are not visible under DELEGATECALL, so the
 *         caller passes them in as {Ctx}. Errors are declared here as well as on the vault: a custom
 *         error selector is derived from its signature alone, so `ZeroShares()` raised here is
 *         indistinguishable from the vault's own.
 */
library V3ProviderLib {
  /// @dev Fixed-point scale for the deposit composition-ratio math.
  uint256 internal constant WAD = 1e18;

  error ZeroShares();
  error OracleZero();

  /// @param adapter DEX adapter holding the position.
  /// @param oracle  Resilient oracle pricing TOKEN0/TOKEN1 in 8-decimal USD.
  struct Ctx {
    address adapter;
    address oracle;
    address token0;
    address token1;
    uint8 dec0;
    uint8 dec1;
  }

  /// @notice 8-decimal USD value of a (amount0, amount1) pair at the resilient oracle's prices.
  function amountsValueUsd(Ctx memory c, uint256 amount0, uint256 amount1) external view returns (uint256) {
    return _amountsValueUsd(c, amount0, amount1);
  }

  /// @notice The shares a deposit mints and the amounts it consumes — pro-rata of the live composition.
  /// @dev Both the consumed amounts and the share credit come from the composition the vault holds at the
  ///      CURRENT pool price — the same composition `removeLiquidity` hands back on the way out. Issuance
  ///      and redemption therefore share one basis, so a deposit followed by an immediate exit returns the
  ///      principal (to the wei: amounts round UP and shares round DOWN, so any dust stays with the
  ///      existing holders), and the price a depositor enters at is the price they can leave at.
  ///
  ///      This does NOT make an entry manipulation-proof. A third party can move the pool price before the
  ///      deposit lands, which shifts the composition and so the ratio the deposit binds to; the depositor
  ///      then buys a skewed basket that is worth less once the price reverts, up to the position's
  ///      convexity span over the range. The credit stays fair FOR that price — nothing is over- or
  ///      under-issued — so the guard is the caller's per-leg `amount0Min`/`amount1Min`. Those are a
  ///      tolerance, not a switch: they reject any shift that starves a leg past its floor and permit
  ///      every shift below it, so what they leave the depositor exposed to is exactly the tolerance the
  ///      caller chose. Size them off a fresh `previewDepositAmounts` quote with a tight band — at the
  ///      configured +/-50 bps range the composition is hypersensitive, and a 3 bps price nudge already
  ///      moves the starved leg to 84% of its quote — and pass a non-zero `minShares` alongside them.
  ///
  ///      A credit taken from the FAIR composition instead would put issuance and redemption on two
  ///      different bases, and the gap between them is exactly the deposit-withdraw cycle Bailsec raised
  ///      (Issue_05). Capping the credit with a spot-composition `min()` does not close that gap either:
  ///      the per-leg fraction is first order in the spot-vs-fair deviation, so it taxes an ordinary
  ///      deposit far harder than the second-order leak it was meant to remove.
  ///
  ///      The pool price stays out of the *collateral valuation* path: {V3ProviderOracle} still prices the
  ///      share off the rate-anchored fair composition. That is not a second basis an attacker can
  ///      arbitrage — it mints and burns nothing — and by LP convexity a redemption at any spot returns at
  ///      least the oracle's fair value, so the oracle errs conservative. `haircutBps` carries that gap.
  function quoteDeposit(
    Ctx memory c,
    uint256 supplyBefore,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
    IV3DexAdapter adapter = IV3DexAdapter(c.adapter);
    (uint256 t0, uint256 t1) = adapter.positionAmountsAt(adapter.spotSqrtPriceX96());
    if (_amountsValueUsd(c, t0, t1) == 0) revert ZeroShares();

    uint256 frac = _compositionFractionWad(amount0Desired, amount1Desired, t0, t1);
    amount0Used = (t0 * frac + WAD - 1) / WAD;
    amount1Used = (t1 * frac + WAD - 1) / WAD;
    shares = (supplyBefore * frac) / WAD;
  }

  function _amountsValueUsd(Ctx memory c, uint256 amount0, uint256 amount1) internal view returns (uint256) {
    uint256 price0 = IOracle(c.oracle).peek(c.token0); // 8 decimals
    uint256 price1 = IOracle(c.oracle).peek(c.token1); // 8 decimals
    // Fail closed: a broken feed on either leg (price 0) must revert, not silently value the position on
    // one leg (which would under-price the collateral and enable unfair liquidation / over-borrow).
    if (price0 == 0 || price1 == 0) revert OracleZero();
    return (amount0 * price0) / (10 ** c.dec0) + (amount1 * price1) / (10 ** c.dec1);
  }

  /// @dev Per-leg fraction of a composition that (amount0, amount1) covers: min(a0/c0, a1/c1) in WAD.
  function _compositionFractionWad(
    uint256 amount0,
    uint256 amount1,
    uint256 comp0,
    uint256 comp1
  ) internal pure returns (uint256) {
    if (comp0 == 0) return (amount1 * WAD) / comp1;
    if (comp1 == 0) return (amount0 * WAD) / comp0;
    uint256 frac0 = (amount0 * WAD) / comp0;
    uint256 frac1 = (amount1 * WAD) / comp1;
    return frac0 < frac1 ? frac0 : frac1;
  }
}

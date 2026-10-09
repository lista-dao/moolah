// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";

import { IStableSwap, IStableSwapPoolInfo } from "../../src/dex/interfaces/IStableSwap.sol";
import { IStableSwapLP } from "../../src/dex/interfaces/IStableSwapLP.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title StableSwapPoolDiff
/// @notice Reference values that a pool implementation must reproduce, measured against the live BSC
///         pools: pro-rata redemption wei-for-wei, the virtual-price bound, the reserve ratio, and the
///         exact surface `SmartProvider.peek()` reads.
/// @dev Runs against whichever implementation the proxies are currently on, so the numbers it records
///      are the baseline a replacement implementation is compared to.
contract StableSwapPoolDiffTest is Test {
  uint256 constant FORK_BLOCK = 122_380_000;

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  uint256 constant PRECISION = 1e18;

  /// @dev Upper bound on the virtual-price change when `D / supply` is replaced by the
  ///      constant-sum `Σ(balances_i × RATES_i / PRECISION) / supply`. Measured across all 15
  ///      live pools (BSC + Ethereum); the largest observed was slisBNB/BNB at +0.3546%.
  ///      The re-basing must never be negative — that direction would lower collateral value
  ///      and could push live positions into liquidation.
  uint256 constant MAX_VP_REBASE_BPS = 40; // 0.40%, headroom over the measured 0.3546%

  struct Pool {
    string name;
    address pool;
    address provider; // SmartProvider — doubles as the market oracle
    address collateral; // StableSwapLPCollateral (Moolah collateral token)
  }

  Pool[] internal pools;

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    pools.push(
      Pool(
        "USDC/USDT",
        0xF5448fC2bEB9324900d08225fE4530bA3bBf654f,
        0x5fD3971104cF3bAB1dC89EF904Da26F54f75C06B,
        0x23BC296d67619eA11C9a8B49B8C396B798AF3330
      )
    );
    pools.push(
      Pool(
        "slisBNB/BNB",
        0x3DcEA6AFBA8af84b25F1f8947058AF1ac4c06131,
        0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE,
        0x719f6445cdAC08B84611D0F19d733F57214bcfee
      )
    );
    pools.push(
      Pool(
        "U/USDT",
        0x6783a05B98Cb83c3f456197A035b9C17a9d57388,
        0x9994D77E5cdcAD9f9055b13402A7BF8C24d4C841,
        0xbBD3e74E69e6BDDDA8e5AAdC1460611A8f7cd05a
      )
    );
    pools.push(
      Pool(
        "lisUSD/USDT",
        0x8df7891fb2Cb3e98C7AB3cfB4d9A59FbCC63c956,
        0x6A39B04f8a7DB71Cee17f9978004C028bfF2e144,
        0x6c7EbA17dDB5D0435FCFb9053BB3087c1d10beB3
      )
    );
    pools.push(
      Pool(
        "USD1/USDT",
        0x723ccd2FB5897673Ad108706578886baA15d7242,
        0x791cd65F2B8cB7cA3a6c1C4D28A0b23D8E566495,
        0x091e6Ed7794d74b73081D32cAb59fa47ff15418d
      )
    );
    pools.push(
      Pool(
        "solvBTC/BTCB",
        0x45409865870f0CBC71c01CC00fF8c0b2DE3EB7D9,
        0xA5F53ca56d87d7d4fEC508665D23f29bfb2749DB,
        0x6f4d7532A402D76F552E1F047Ff7e23bFe1A9f03
      )
    );
    pools.push(
      Pool(
        "lisAster/ASTER",
        0x510D69b25A2177EDdCe9becdB0A66a511C944840,
        0x1cc913Cde4dF80d271230F615482c1270c0a56C8,
        0xC970dc3aF680C2F316b821842E5782a05e886a90
      )
    );
  }

  /* ------------------------------------------------------------------ *
   *  1. Redemption equivalence — any implementation must reproduce this wei-for-wei
   * ------------------------------------------------------------------ */

  /// @notice Proportional redemption pays exactly `floor(balances[i] * lp / supply)` on every leg.
  /// @dev `SmartProvider.withdrawCollateral` and the liquidator's `redeemLpCollateral` both route
  ///      through `remove_liquidity`, so any implementation must return identical amounts or user exits
  ///      and liquidations change behaviour.
  function test_proportionalRedeem_paysExactProRata() public {
    address redeemer = makeAddr("redeemer");

    for (uint256 p = 0; p < pools.length; p++) {
      Pool memory cfg = pools[p];
      IStableSwap pool = IStableSwap(cfg.pool);
      address lpToken = pool.token();
      if (IStableSwapLP(lpToken).totalSupply() == 0) continue;

      uint256 lpAmount = IERC20(lpToken).balanceOf(cfg.provider) / 1000;
      if (lpAmount == 0) continue;

      // Redeem from a plain EOA rather than the SmartProvider. The provider's `receive()` re-reads
      // `dex` from storage, and the pool forwards only `bnb_gas` (4029) — production always arrives
      // with that slot warm because the provider read `dex` to make the call, but a test that pokes
      // the pool directly leaves it cold and the native leg reverts. The payout math under test is
      // unaffected; mint through the pool's own minter right so no storage is faked.
      vm.prank(cfg.pool);
      IStableSwapLP(lpToken).mint(redeemer, lpAmount);

      uint256 supply = IStableSwapLP(lpToken).totalSupply();
      uint256[2] memory expected;
      uint256[2] memory before;
      for (uint256 i = 0; i < 2; i++) {
        expected[i] = (pool.balances(i) * lpAmount) / supply;
        before[i] = _selfBalance(pool.coins(i), redeemer);
      }

      vm.prank(redeemer);
      pool.remove_liquidity(lpAmount, [uint256(0), uint256(0)]);

      for (uint256 i = 0; i < 2; i++) {
        uint256 received = _selfBalance(pool.coins(i), redeemer) - before[i];
        assertEq(received, expected[i], string.concat(cfg.name, ": payout must equal floor(bal*lp/supply)"));
      }
    }
  }

  /* ------------------------------------------------------------------ *
   *  2. Virtual price — the documented re-basing bound
   * ------------------------------------------------------------------ */

  /// @notice Valuing the LP token at its reserve value rather than at the invariant must move collateral
  ///         valuation UPWARD only, and by no more than {MAX_VP_REBASE_BPS}.
  /// @dev A negative move would lower every position's collateral value and could trigger liquidations;
  ///      an oversized positive one would silently widen borrow capacity.
  function test_virtualPrice_rebaseIsUpwardAndBounded() public {
    for (uint256 p = 0; p < pools.length; p++) {
      Pool memory cfg = pools[p];
      IStableSwap pool = IStableSwap(cfg.pool);
      uint256 supply = IStableSwapLP(pool.token()).totalSupply();
      if (supply == 0) continue;

      uint256 current = pool.get_virtual_price(); // D / supply
      uint256 reserveValue = _constantSumVirtualPrice(pool, supply); // Σ(bal_i × RATES_i) / supply

      assertGe(reserveValue, current, string.concat(cfg.name, ": reserve-value vp must not be the lower one"));

      uint256 rebaseBps = ((reserveValue - current) * 10_000) / current;
      assertLe(rebaseBps, MAX_VP_REBASE_BPS, string.concat(cfg.name, ": vp re-basing exceeds the bound"));

      emit log_named_string("pool", cfg.name);
      emit log_named_uint("  vp  now  ", current);
      emit log_named_uint("  vp  reserve", reserveValue);
      emit log_named_uint("  rebase bps", rebaseBps);
    }
  }

  /* ------------------------------------------------------------------ *
   *  3. Oracle path — what peek() actually touches
   * ------------------------------------------------------------------ */

  /// @notice `SmartProvider.peek(collateral)` equals `min(peek(coin0), peek(coin1)) * get_virtual_price()`.
  /// @dev Pins the borrow / liquidation health-check surface down to exactly two pool reads —
  ///      `coins(i)` and `get_virtual_price()` — so only those two have to be preserved.
  function test_peek_dependsOnlyOnCoinsAndVirtualPrice() public {
    for (uint256 p = 0; p < pools.length; p++) {
      Pool memory cfg = pools[p];
      IStableSwap pool = IStableSwap(cfg.pool);
      if (IStableSwapLP(pool.token()).totalSupply() == 0) continue;

      uint256 reported = IOracle(cfg.provider).peek(cfg.collateral);

      uint256 price0 = IOracle(cfg.provider).peek(pool.coins(0));
      uint256 price1 = IOracle(cfg.provider).peek(pool.coins(1));
      uint256 minPrice = price0 < price1 ? price0 : price1;
      uint256 expected = (minPrice * pool.get_virtual_price()) / PRECISION;

      assertEq(reported, expected, string.concat(cfg.name, ": peek must be min(p0,p1) * vp"));
      assertGt(reported, 0, string.concat(cfg.name, ": collateral price must never be zero"));
    }
  }

  /* ------------------------------------------------------------------ *
   *  4. Ratio invariance
   * ------------------------------------------------------------------ */

  /// @notice A proportional redemption leaves the reserve ratio unchanged up to rounding dust.
  /// @dev With no swap available the composition cannot be moved at all, which is what makes the LP
  ///      oracle unmanipulable. Asserted here so any implementation is held to the same standard.
  function test_proportionalRedeem_preservesReserveRatio() public {
    address redeemer = makeAddr("ratioRedeemer");

    for (uint256 p = 0; p < pools.length; p++) {
      Pool memory cfg = pools[p];
      IStableSwap pool = IStableSwap(cfg.pool);
      address lpToken = pool.token();
      if (IStableSwapLP(lpToken).totalSupply() == 0) continue;

      uint256 b0 = pool.balances(0);
      uint256 b1 = pool.balances(1);
      if (b0 == 0 || b1 == 0) continue;
      uint256 ratioBefore = (b0 * PRECISION) / b1;

      uint256 lpAmount = IERC20(lpToken).balanceOf(cfg.provider) / 1000;
      if (lpAmount == 0) continue;

      vm.prank(cfg.pool);
      IStableSwapLP(lpToken).mint(redeemer, lpAmount);

      vm.prank(redeemer);
      pool.remove_liquidity(lpAmount, [uint256(0), uint256(0)]);

      uint256 ratioAfter = (pool.balances(0) * PRECISION) / pool.balances(1);
      uint256 drift = ratioAfter > ratioBefore ? ratioAfter - ratioBefore : ratioBefore - ratioAfter;

      // Dust only: the ratio may move by at most 1 part in 1e12 of itself.
      assertLe(drift, ratioBefore / 1e12 + 1, string.concat(cfg.name, ": reserve ratio drifted"));
    }
  }

  /* ------------------------------------------------------------------ *
   *  helpers
   * ------------------------------------------------------------------ */

  /// @dev `Σ(balances_i × RATES_i / PRECISION) × PRECISION / supply` — the pool's intrinsic LP value.
  function _constantSumVirtualPrice(IStableSwap pool, uint256 supply) internal view returns (uint256) {
    uint256 total;
    for (uint256 i = 0; i < 2; i++) {
      total += (pool.balances(i) * pool.RATES(i)) / PRECISION;
    }
    return (total * PRECISION) / supply;
  }

  function _selfBalance(address coin, address who) internal view returns (uint256) {
    return coin == BNB_ADDRESS ? who.balance : IERC20(coin).balanceOf(who);
  }
}

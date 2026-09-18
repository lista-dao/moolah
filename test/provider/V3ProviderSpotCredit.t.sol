// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IV3DexAdapter } from "../../src/provider/interfaces/IV3DexAdapter.sol";
import { IV3Provider } from "../../src/provider/interfaces/IV3Provider.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { MarketParams } from "moolah/interfaces/IMoolah.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";

import { V3Provider } from "../../src/provider/v3/V3Provider.sol";
import { SlisBNBV3ProviderTest, PoolSwapper } from "./SlisBNBV3Provider.t.sol";

/// @dev One actor that funds its own manipulation: the swaps that move the pool price are paid for out of
///      the same inventory the deposit comes from, and the LP position is entered and exited from the same
///      address. Measuring this address's whole token inventory before and after therefore prices the
///      cycle end to end — the convexity gain on the LP leg AND the cost of the swaps that produced it.
contract SelfFinancedEntrant {
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  address internal immutable POOL;
  address internal immutable TOKEN0;
  address internal immutable TOKEN1;

  constructor(address pool, address token0, address token1) {
    POOL = pool;
    TOKEN0 = token0;
    TOKEN1 = token1;
  }

  /// @param zeroForOne true → token0 in, price down; false → token1 in, price up.
  function swap(bool zeroForOne, uint256 amountIn) external {
    uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    IListaV3Pool(POOL).swap(address(this), zeroForOne, int256(amountIn), limit, "");
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    _pay(amount0Delta, amount1Delta);
  }

  function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    _pay(amount0Delta, amount1Delta);
  }

  function _pay(int256 amount0Delta, int256 amount1Delta) internal {
    if (amount0Delta > 0) IERC20(TOKEN0).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(TOKEN1).transfer(msg.sender, uint256(amount1Delta));
  }

  function enter(
    IV3Provider provider,
    MarketParams calldata marketParams,
    uint256 amount0,
    uint256 amount1
  ) external returns (uint256 shares, uint256 used0, uint256 used1) {
    IERC20(TOKEN0).approve(address(provider), amount0);
    IERC20(TOKEN1).approve(address(provider), amount1);
    return provider.deposit(marketParams, amount0, amount1, 0, 0, 0, address(this));
  }

  function exit(
    IV3Provider provider,
    MarketParams calldata marketParams,
    uint256 shares
  ) external returns (uint256 out0, uint256 out1) {
    provider.withdrawShares(marketParams, shares, address(this), address(this));
    return provider.redeemShares(shares, 0, 0, address(this));
  }

  /// @dev The wrapped-native leg of a refund / redemption arrives as the native coin.
  receive() external payable {}
}

/// @dev Deposit credit must be pro-rata of the composition the vault actually holds right now, so that a
///      deposit and an immediate redeem cancel. That does NOT make an entry manipulation-proof: a third
///      party can still move the pool price first, which shifts the composition the deposit binds to. The
///      credit stays fair for that price — nothing is over-issued — and the guard against the skewed ratio
///      is the caller's per-leg amount0Min / amount1Min. Both halves are pinned below.
contract V3ProviderSpotCreditTest is SlisBNBV3ProviderTest {
  PoolSwapper swapper;
  address entrant = makeAddr("entrant");

  function _spotDevBps() internal view returns (uint256) {
    uint256 spot = IV3DexAdapter(address(adapter)).spotSqrtPriceX96();
    uint256 fair = IV3DexAdapter(address(adapter)).fairSqrtPriceX96();
    uint256 pSpot = FullMath.mulDiv(spot * spot, 1e18, 1 << 192);
    uint256 pFair = FullMath.mulDiv(fair * fair, 1e18, 1 << 192);
    return pSpot > pFair ? ((pSpot - pFair) * 10_000) / pFair : ((pFair - pSpot) * 10_000) / pFair;
  }

  /// @dev Signed spot-vs-fair deviation in bps: positive when spot sits ABOVE the rate-anchored fair.
  ///      The absolute form above cannot tell a walk towards fair from a walk past it.
  function _signedSpotDevBps() internal view returns (int256) {
    uint256 spot = IV3DexAdapter(address(adapter)).spotSqrtPriceX96();
    uint256 fair = IV3DexAdapter(address(adapter)).fairSqrtPriceX96();
    uint256 pSpot = FullMath.mulDiv(spot * spot, 1e18, 1 << 192);
    uint256 pFair = FullMath.mulDiv(fair * fair, 1e18, 1 << 192);
    return pSpot >= pFair ? int256(((pSpot - pFair) * 10_000) / pFair) : -int256(((pFair - pSpot) * 10_000) / pFair);
  }

  /// @dev Walk spot in one direction, one small step at a time, until it reaches `targetBps` (signed).
  ///      Small steps matter: past the position's own tick bound the vault holds the last liquidity in
  ///      the pool's local range, so a single large swap gaps the price by orders of magnitude.
  function _walkSpotTo(int256 targetBps) internal {
    if (address(swapper) == address(0)) {
      swapper = new PoolSwapper();
      deal(WBNB, address(swapper), 2_000_000 ether);
      deal(SLISBNB, address(swapper), 2_000_000 ether);
    }
    bool up = _signedSpotDevBps() < targetBps;
    for (uint256 i = 0; i < 400; i++) {
      if (up ? _signedSpotDevBps() >= targetBps : _signedSpotDevBps() <= targetBps) break;
      swapper.swapExactIn(POOL, !up, 0.5 ether);
    }
    int256 reached = _signedSpotDevBps();
    assertApproxEqAbs(reached, targetBps, 3, "setup: spot did not settle at the requested deviation");
  }

  /// @dev Walk the pool away from fair in small steps until the deviation clears `targetBps`.
  function _pushSpot(uint256 targetBps, bool up) internal {
    if (address(swapper) == address(0)) {
      swapper = new PoolSwapper();
      deal(WBNB, address(swapper), 2_000_000 ether);
      deal(SLISBNB, address(swapper), 2_000_000 ether);
    }
    for (uint256 i = 0; i < 400 && _spotDevBps() < targetBps; i++) {
      swapper.swapExactIn(POOL, !up, 2 ether);
    }
    assertGe(_spotDevBps(), targetBps, "setup: could not move spot far enough");
  }

  function _spotComposition() internal view returns (uint256 s0, uint256 s1) {
    return IV3DexAdapter(address(adapter)).positionAmountsAt(IV3DexAdapter(address(adapter)).spotSqrtPriceX96());
  }

  /// A depositor handing over one tenth of the live composition must receive one tenth of the supply,
  /// however far the pool price sits from the exchange rate.
  function test_depositCreditIsProRataOfLiveComposition() public {
    _deposit(user, 20 ether, 20 ether);
    _deposit(user2, 20 ether, 20 ether);
    _pushSpot(30, false);

    (uint256 s0, uint256 s1) = _spotComposition();
    uint256 supply = provider.totalSupply();
    uint256 credited = provider.previewDepositShares(s0 / 10, s1 / 10);
    uint256 expected = supply / 10;

    emit log_named_uint("spot-vs-fair dev bps", _spotDevBps());
    emit log_named_uint("shares credited", credited);
    emit log_named_uint("shares pro-rata", expected);
    assertApproxEqRel(credited, expected, 1e12, "deposit credit is not pro-rata of the live composition");
  }

  /// Deposit then immediate redeem at an unchanged pool price must return what was handed over, and never
  /// more: the round-up on the consumed amounts leaves the surplus with the existing holders.
  function test_depositThenRedeemAtUnchangedSpotReturnsPrincipal() public {
    _deposit(user, 20 ether, 20 ether);
    _deposit(user2, 20 ether, 20 ether);
    _pushSpot(30, false);

    (uint256 s0, uint256 s1) = _spotComposition();
    uint256 want0 = s0 / 10;
    uint256 want1 = s1 / 10;

    deal(SLISBNB, entrant, want0);
    deal(WBNB, entrant, want1);
    vm.startPrank(entrant);
    IERC20(SLISBNB).approve(address(provider), want0);
    IERC20(WBNB).approve(address(provider), want1);
    (uint256 shares, uint256 used0, uint256 used1) = provider.deposit(marketParams, want0, want1, 0, 0, 0, entrant);
    vm.stopPrank();

    vm.prank(entrant);
    provider.withdrawShares(marketParams, shares, entrant, entrant);
    vm.prank(entrant);
    (uint256 back0, uint256 back1) = provider.redeemShares(shares, 0, 0, entrant);

    emit log_named_uint("used0", used0);
    emit log_named_uint("back0", back0);
    emit log_named_uint("used1", used1);
    emit log_named_uint("back1", back1);
    assertApproxEqRel(back0, used0, 1e12, "token0 principal not returned");
    assertApproxEqRel(back1, used1, 1e12, "token1 principal not returned");
    assertLe(back0, used0, "token0 over-returned: holders diluted");
    assertLe(back1, used1, "token1 over-returned: holders diluted");
  }

  /// A one-sided deposit while the live composition is two-sided is not proportional: it binds the
  /// fraction to the leg it did not fund, so it mints nothing and reverts rather than under-crediting.
  function test_deposit_oneSidedInRange_revertsOnSubsequentDeposit() public {
    _deposit(user, 20 ether, 20 ether);

    (uint256 s0, uint256 s1) = _spotComposition();
    assertGt(s0, 0, "in range: composition holds token0");
    assertGt(s1, 0, "in range: composition holds token1");

    deal(SLISBNB, entrant, 10 ether);
    deal(WBNB, entrant, 10 ether);
    vm.startPrank(entrant);
    IERC20(SLISBNB).approve(address(provider), 10 ether);
    IERC20(WBNB).approve(address(provider), 10 ether);
    vm.expectRevert(V3Provider.ZeroShares.selector);
    provider.deposit(marketParams, 10 ether, 0, 0, 0, 0, entrant);
    vm.expectRevert(V3Provider.ZeroShares.selector);
    provider.deposit(marketParams, 0, 10 ether, 0, 0, 0, entrant);
    vm.stopPrank();
  }

  /// The residual this design accepts, and its price. LP value at fixed liquidity is convex with its
  /// minimum at the rate, so entering with spot on the rate and exiting with spot at the edge of the band
  /// does hand the entrant fair value — bounded by (rangeLower + rangeUpper) / 8, i.e. 12.5 bps at the
  /// configured +/-50 bps. The point of this test is that the bound is GROSS: the swaps that walk the pool
  /// from the rate to the band edge are paid for out of the same inventory, and they cost strictly more
  /// than the convexity they unlock. Everything the actor touches — swap legs, deposit, redemption, the
  /// native-coin leg of the refund — is one balance sheet, valued at the oracle's prices before and after.
  function test_selfFinancedManipulationCycle_isNotProfitable() public {
    _deposit(user, 20 ether, 20 ether);
    _deposit(user2, 20 ether, 20 ether);

    SelfFinancedEntrant atk = new SelfFinancedEntrant(POOL, SLISBNB, WBNB);
    uint256 seed0 = 200 ether;
    uint256 seed1 = 200 ether;
    deal(SLISBNB, address(atk), seed0);
    deal(WBNB, address(atk), seed1);
    uint256 valueBefore = _valueUSD(seed0, seed1);

    // 1) Walk spot onto the exchange rate with the actor's own inventory: the cheapest entry basket.
    for (uint256 i = 0; i < 200 && _spotDevBps() > 1; i++) {
      atk.swap(false, 0.5 ether);
    }
    uint256 entryDev = _spotDevBps();
    emit log_named_uint("entry dev bps", entryDev);
    assertLe(entryDev, 1, "setup: entry must sit on the rate");

    // 2) Enter pro-rata of the live composition.
    (uint256 s0, uint256 s1) = _spotComposition();
    (uint256 shares, uint256 in0, uint256 in1) = atk.enter(
      IV3Provider(address(provider)),
      marketParams,
      s0 / 10,
      s1 / 10
    );
    assertGt(shares, 0, "setup: entry minted shares");

    // 3) Walk spot to the top of the band, where the position is richest at oracle prices. Stop INSIDE
    //    the band: past tickUpper the vault's own liquidity is the last in the pool's local range, so one
    //    more swap gaps the price by orders of magnitude and stops describing any real manipulation.
    for (uint256 i = 0; i < 400 && _spotDevBps() < 45; i++) {
      atk.swap(false, 0.5 ether);
    }
    uint256 exitDev = _spotDevBps();
    emit log_named_uint("exit dev bps", exitDev);
    assertGe(exitDev, 45, "setup: spot did not reach the band edge");
    assertLt(exitDev, adapter.rangeUpperBps(), "setup: spot gapped out of the band, cycle is not realistic");

    // 4) Exit the LP leg.
    (uint256 out0, uint256 out1) = atk.exit(IV3Provider(address(provider)), marketParams, shares);

    // The LP leg alone, gross of what moving the price cost: this is the convexity bound.
    uint256 vIn = _valueUSD(in0, in1);
    uint256 vOut = _valueUSD(out0, out1);
    uint256 lpGainBps = vOut > vIn ? ((vOut - vIn) * 10_000) / vIn : 0;
    emit log_named_uint("LP leg gain bps (gross of swap cost)", lpGainBps);
    assertLe(lpGainBps, 50, "LP leg gain must stay inside the range-width bound");

    // The whole balance sheet. The wrapped-native leg comes back as the native coin, so count it.
    uint256 valueAfter = _valueUSD(
      IERC20(SLISBNB).balanceOf(address(atk)),
      IERC20(WBNB).balanceOf(address(atk)) + address(atk).balance
    );
    emit log_named_uint("inventory value before", valueBefore);
    emit log_named_uint("inventory value after", valueAfter);
    assertLe(valueAfter, valueBefore, "self-financed manipulation cycle must not be profitable");
  }

  /* ───────── F1: sandwiching a zero-min deposit, and the guard against it ───────── */

  /// F1 (accepted residual). A deposit that passes amount0Min = amount1Min = 0 can be sandwiched. The
  /// front-run shifts the live composition, the victim binds to the skewed ratio and buys a basket that is
  /// worth less once the price reverts; the difference accrues to the existing holders — the attacker
  /// among them. Nothing is over-issued: the credit is fair FOR the manipulated price. No auditor raised
  /// this because the audited code issued on the rate-anchored fair composition, which no swap can move.
  /// Pinned here so the residual is measured rather than assumed, and bounded so it cannot grow silently.
  ///
  /// Both arms start from spot ON the rate, so the only difference between them is the sandwich.
  function test_zeroMinDeposit_canBeSandwichedByIncumbentHolder() public {
    _deposit(user, 100 ether, 100 ether); // the incumbent holder / attacker
    _walkSpotTo(0);

    // Arm A: nobody interferes. Deposit and redeem at the same price.
    uint256 snap = vm.snapshotState();
    uint256 undisturbedLossBps = _depositRedeemLossBps(0);
    vm.revertToState(snap);

    // Arm B: the attacker walks spot up before the deposit and back down before the redemption.
    uint256 sandwichedLossBps = _depositRedeemLossBps(30);

    emit log_named_uint("victim loss bps, undisturbed", undisturbedLossBps);
    emit log_named_uint("victim loss bps, sandwiched", sandwichedLossBps);
    assertGt(sandwichedLossBps, undisturbedLossBps, "the sandwich must be measurable, or F1 is not pinned");
    assertLe(sandwichedLossBps, 100, "sandwich cost to a zero-min depositor must stay bounded");
  }

  /// @dev Deposit with zero mins while spot sits `frontRunBps` above fair, then redeem once spot is back
  ///      on the rate. Returns the victim's realized loss in bps of what the deposit consumed.
  function _depositRedeemLossBps(int256 frontRunBps) internal returns (uint256) {
    if (frontRunBps != 0) _walkSpotTo(frontRunBps);
    (uint256 shares, uint256 used0, uint256 used1) = _depositWithMin(entrant, 100 ether, 100 ether, 0, 0);
    if (frontRunBps != 0) _walkSpotTo(0);

    vm.prank(entrant);
    provider.withdrawShares(marketParams, shares, entrant, entrant);
    vm.prank(entrant);
    (uint256 back0, uint256 back1) = provider.redeemShares(shares, 0, 0, entrant);
    return _lossBps(_valueUSD(used0, used1), _valueUSD(back0, back1));
  }

  /// The guard. Per-leg mins sized off an honest preview reject the skewed ratio outright. A composition
  /// shift always starves a leg: the leg that becomes binding consumes all of its desired amount, and the
  /// other consumes t_i · frac, which falls on both factors. Skewing spot up makes token1 binding, so
  /// token0 is the starved leg and amount0Min is what reverts.
  function test_nonZeroAmountMins_rejectTheSandwichedRatio() public {
    _deposit(user, 100 ether, 100 ether);

    // Quote the honest ratio first, exactly as an integration would before broadcasting.
    (, uint256 expect0, uint256 expect1) = provider.previewDepositAmounts(100 ether, 100 ether);
    uint256 min0 = (expect0 * 99) / 100;
    uint256 min1 = (expect1 * 99) / 100;
    assertGt(min0, 0, "setup: token0 leg is quoted");
    assertGt(min1, 0, "setup: token1 leg is quoted");

    _skewSpotUp(300 ether); // the front-run

    deal(SLISBNB, entrant, 100 ether);
    deal(WBNB, entrant, 100 ether);
    vm.startPrank(entrant);
    IERC20(SLISBNB).approve(address(provider), 100 ether);
    IERC20(WBNB).approve(address(provider), 100 ether);
    vm.expectRevert(V3Provider.InsufficientAmount.selector);
    provider.deposit(marketParams, 100 ether, 100 ether, min0, min1, 0, entrant);
    vm.stopPrank();
  }

  function _lossBps(uint256 paid, uint256 returned) internal pure returns (uint256) {
    return returned >= paid ? 0 : ((paid - returned) * 10_000) / paid;
  }
}

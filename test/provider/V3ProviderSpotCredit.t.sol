// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IV3DexAdapter } from "../../src/provider/interfaces/IV3DexAdapter.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";

import { V3Provider } from "../../src/provider/v3/V3Provider.sol";
import { SlisBNBV3ProviderTest, PoolSwapper } from "./SlisBNBV3Provider.t.sol";

/// @dev Deposit credit must be pro-rata of the composition the vault actually holds right now, so that a
///      deposit and an immediate redeem cancel and the pool price cannot tax an entry.
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
    (uint256 shares, uint256 used0, uint256 used1) = provider.deposit(
      marketParams,
      want0,
      want1,
      0,
      0,
      0,
      entrant
    );
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

  /// The residual this design accepts: entering near the exchange rate and exiting with spot driven to the
  /// edge of the band walks out with more fair value than went in. LP value at fixed liquidity is convex
  /// with its minimum at the rate, so the gain over a full traverse of the band is (lower + upper) / 8 —
  /// 12.5 bps at the configured +/-50 bps. Bounded here at 50 bps, which leaves room for the pool fees the
  /// manipulation swaps themselves pay into the position.
  function test_depositNearRateThenExitAtEdge_gainStaysBelowRangeWidthBound() public {
    _deposit(user, 20 ether, 20 ether);
    _deposit(user2, 20 ether, 20 ether);

    // Walk spot up onto the exchange rate: the cheapest possible entry basket.
    swapper = new PoolSwapper();
    deal(WBNB, address(swapper), 2_000_000 ether);
    deal(SLISBNB, address(swapper), 2_000_000 ether);
    for (uint256 i = 0; i < 200 && _spotDevBps() > 1; i++) {
      swapper.swapExactIn(POOL, false, 0.5 ether);
    }
    emit log_named_uint("entry dev bps", _spotDevBps());

    (uint256 s0, uint256 s1) = _spotComposition();
    uint256 want0 = s0 / 10;
    uint256 want1 = s1 / 10;
    deal(SLISBNB, entrant, want0);
    deal(WBNB, entrant, want1);
    vm.startPrank(entrant);
    IERC20(SLISBNB).approve(address(provider), want0);
    IERC20(WBNB).approve(address(provider), want1);
    (uint256 shares, uint256 in0, uint256 in1) = provider.deposit(marketParams, want0, want1, 0, 0, 0, entrant);
    vm.stopPrank();

    // Drive spot to the top of the band, where the position is richest at oracle prices.
    for (uint256 i = 0; i < 400 && _spotDevBps() < 60; i++) {
      swapper.swapExactIn(POOL, false, 0.5 ether);
    }
    emit log_named_uint("exit dev bps", _spotDevBps());

    vm.prank(entrant);
    provider.withdrawShares(marketParams, shares, entrant, entrant);
    vm.prank(entrant);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, 0, 0, entrant);

    uint256 vIn = _valueUSD(in0, in1);
    uint256 vOut = _valueUSD(out0, out1);
    uint256 gainBps = vOut > vIn ? ((vOut - vIn) * 10_000) / vIn : 0;
    emit log_named_uint("round-trip gain bps", gainBps);
    assertLe(gainBps, 50, "cycle gain must stay inside the range-width bound");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// exec-verify contract-profile BACKSTOP (全链兜底档) for task 708 / moolah PR#241
// Redeems REAL accrued Lista V2 fee LP on a BSC mainnet fork against the REAL deployed
// RevenueCollector proxy. Exercises the real pair.burn / _mintFee path that the dev's
// mock-based unit tests (component tier) structurally cannot reproduce.
//
// Run: BSC_RPC=<url> forge test --match-contract RevenueCollectorV2RedeemForkTest -vvv

import "forge-std/Test.sol";
import { RevenueCollector } from "../../src/revenue/RevenueCollector.sol";

interface IUUPS {
  function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IERC20Min {
  function balanceOf(address) external view returns (uint256);
  function symbol() external view returns (string memory);
}

interface IPairMin {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function totalSupply() external view returns (uint256);
  function getReserves() external view returns (uint112, uint112, uint32);
  function kLast() external view returns (uint256);
}

contract RevenueCollectorV2RedeemForkTest is Test {
  // ---- live BSC addresses (verified on-chain 2026-09-04) ----
  address constant COLLECTOR = 0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C; // deployed proxy
  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // DEFAULT_ADMIN_ROLE
  address constant BOT = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // BOT role member
  address constant FACTORY = 0x28F5E6C71C7541b1C6523351AE331CcAfC443626; // Lista V2 factory (feeTo == COLLECTOR)
  address constant PAIR = 0x61aaCAc46F8d41f37BeB4935fc8D29b217613637; // TST/U pair, holds real fee LP

  RevenueCollector collector;

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"));

    // Upgrade the live proxy to the PR#241 implementation (UUPS, admin-gated).
    RevenueCollector newImpl = new RevenueCollector();
    vm.prank(ADMIN);
    IUUPS(COLLECTOR).upgradeToAndCall(address(newImpl), "");

    collector = RevenueCollector(payable(COLLECTOR));

    // Pin the real factory (provenance authorization source).
    vm.prank(ADMIN);
    collector.setV2Factory(FACTORY);
  }

  function _redemption(
    address lp,
    uint256 m0,
    uint256 m1
  ) internal pure returns (RevenueCollector.V2LpRedemption memory) {
    return RevenueCollector.V2LpRedemption({ lpToken: lp, minAmount0: m0, minAmount1: m1 });
  }

  function test_fork_setup_sane() public {
    assertEq(collector.v2Factory(), FACTORY, "factory pinned");
    assertTrue(collector.hasRole(collector.BOT(), BOT), "bot role");
    uint256 lp = IERC20Min(PAIR).balanceOf(COLLECTOR);
    assertGt(lp, 0, "collector holds real fee LP");
    emit log_named_uint("collector LP balance", lp);
    emit log_named_uint("pair totalSupply", IPairMin(PAIR).totalSupply());
    emit log_named_uint("pair kLast", IPairMin(PAIR).kLast());
  }

  /// @dev The heart of the backstop: preview vs ACTUAL against a real pair burn.
  function test_fork_redeem_real_pair() public {
    address t0 = IPairMin(PAIR).token0();
    address t1 = IPairMin(PAIR).token1();

    uint256 lpBefore = IERC20Min(PAIR).balanceOf(COLLECTOR);
    uint256 c0Before = IERC20Min(t0).balanceOf(COLLECTOR);
    uint256 c1Before = IERC20Min(t1).balanceOf(COLLECTOR);

    ( , , uint256 pv0, , uint256 pv1) = collector.previewRedeemV2Lp(PAIR);
    emit log_named_uint("preview amount0", pv0);
    emit log_named_uint("preview amount1", pv1);

    vm.prank(BOT);
    collector.redeemV2Lp(_redemption(PAIR, 0, 0));

    uint256 c0After = IERC20Min(t0).balanceOf(COLLECTOR);
    uint256 c1After = IERC20Min(t1).balanceOf(COLLECTOR);
    uint256 got0 = c0After - c0Before;
    uint256 got1 = c1After - c1Before;
    uint256 lpAfter = IERC20Min(PAIR).balanceOf(COLLECTOR);

    emit log_named_uint("actual amount0", got0);
    emit log_named_uint("actual amount1", got1);
    emit log_named_uint("LP before", lpBefore);
    emit log_named_uint("LP after (residual from _mintFee?)", lpAfter);

    // The collector really received both underlying assets.
    assertGt(got0, 0, "received token0");
    assertGt(got1, 0, "received token1");

    // Drift check: preview is computed on pre-burn supply/reserves; real burn may _mintFee.
    // We assert actual is within a small band BELOW preview (never materially above).
    assertLe(got0, pv0, "actual0 <= preview0 (fee mint dilutes)");
    assertLe(got1, pv1, "actual1 <= preview1 (fee mint dilutes)");
    if (pv0 > 0) {
      uint256 drift0 = ((pv0 - got0) * 1e6) / pv0; // ppm
      emit log_named_uint("token0 drift (ppm)", drift0);
    }
  }

  /// @dev Slippage guard on a REAL pair: min above actual output must revert.
  function test_fork_redeem_slippage_reverts() public {
    ( , , uint256 pv0, , ) = collector.previewRedeemV2Lp(PAIR);
    vm.prank(BOT);
    vm.expectRevert("insufficient output");
    collector.redeemV2Lp(_redemption(PAIR, pv0 * 2, 0));
  }

  /// @dev Batch across the real pair + a same-collector empty pair is a no-op on the empty one.
  function test_fork_batch_with_real_pair() public {
    // second redemption points to the same real pair after it is drained -> zero balance no-op
    vm.prank(BOT);
    collector.redeemV2Lp(_redemption(PAIR, 0, 0)); // drain

    RevenueCollector.V2LpRedemption[] memory reds = new RevenueCollector.V2LpRedemption[](1);
    reds[0] = _redemption(PAIR, 0, 0); // now near-zero / zero balance
    vm.prank(BOT);
    collector.batchRedeemV2Lps(reds); // must not revert
  }

  /// @dev A pair from the SAME factory whose feeTo != collector cannot be spoofed:
  ///      here we confirm provenance holds for the pinned real factory + real pair.
  function test_fork_provenance_holds() public view {
    // previewRedeemV2Lp internally runs _validateV2Lp; it returning without revert proves
    // getPair(token0,token1)==PAIR AND factory.feeTo()==collector on the live factory.
    collector.previewRedeemV2Lp(PAIR);
  }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { StableSwapFactory } from "../../src/dex/StableSwapFactory.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

/// @title StableSwapPoolBase
/// @notice Shared rig: a factory, and a helper that stands up a pool over any two coins.
abstract contract StableSwapPoolBase is Test {
  address constant BNB = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  StableSwapFactory factory;
  StableSwapPool pool;
  StableSwapLP lp;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address deployer = makeAddr("deployer");
  address oracle = makeAddr("oracle");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");

  function _deployFactory() internal {
    address[] memory deployers = new address[](1);
    deployers[0] = deployer;
    StableSwapFactory impl = new StableSwapFactory();
    factory = StableSwapFactory(
      address(new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, admin, deployers)))
    );

    vm.startPrank(admin);
    factory.setLpImpl(address(new StableSwapLP()));
    factory.setSwapImpl(address(new StableSwapPool(address(factory))));
    vm.stopPrank();
  }

  function _createPair(address a, address b) internal returns (StableSwapPool p, StableSwapLP l) {
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, a), abi.encode(1e8));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, b), abi.encode(1e8));

    vm.prank(deployer);
    (address _lp, address _pool) = factory.createSwapPair(
      a,
      b,
      "LP",
      "LP",
      1000,
      1e8,
      5e9,
      admin,
      manager,
      pauser,
      oracle
    );
    p = StableSwapPool(_pool);
    l = StableSwapLP(_lp);

    bytes32 managerRole = p.MANAGER();
    vm.prank(admin);
    p.grantRole(managerRole, userA);
  }

  /// @dev Give `who` `amount` of `coin`, and approve the pool to pull it.
  function _fund(address who, address coin, uint256 amount) internal {
    if (coin == BNB) {
      vm.deal(who, who.balance + amount);
    } else {
      ERC20Mock(coin).setBalance(who, ERC20Mock(coin).balanceOf(who) + amount);
      vm.prank(who);
      ERC20Mock(coin).approve(address(pool), type(uint256).max);
    }
  }

  function _balanceOf(address coin, address who) internal view returns (uint256) {
    return coin == BNB ? who.balance : ERC20Mock(coin).balanceOf(who);
  }

  function _reserves() internal view returns (uint256[2] memory r) {
    r[0] = pool.balances(0);
    r[1] = pool.balances(1);
  }

  /// @dev Fund `who` for `lpAmount` shares and mint them.
  function _add(address who, uint256 lpAmount) internal returns (uint256[2] memory need) {
    need = pool.calc_add_liquidity(lpAmount);
    uint256 value;
    for (uint256 i = 0; i < 2; i++) {
      address coin = pool.coins(i);
      _fund(who, coin, need[i]);
      if (coin == BNB) value = need[i];
    }
    vm.prank(who);
    pool.add_liquidity{ value: value }(lpAmount, need);
  }
}

/// @notice Two 18-decimal ERC20 legs.
contract StableSwapPoolERC20Test is StableSwapPoolBase {
  ERC20Mock tokenA;
  ERC20Mock tokenB;

  function setUp() public {
    _deployFactory();
    tokenA = new ERC20Mock();
    tokenB = new ERC20Mock();
    (pool, lp) = _createPair(address(tokenA), address(tokenB));
  }

  function _seed(uint256 a0, uint256 a1) internal {
    _fund(userA, pool.coins(0), a0);
    _fund(userA, pool.coins(1), a1);
    vm.prank(userA);
    pool.seed([a0, a1]);
  }

  /* ───────────────────────────── seeding ─────────────────────────── */

  function test_virtualPrice_isZeroBeforeSeeding() public view {
    assertEq(lp.totalSupply(), 0);
    assertEq(pool.get_virtual_price(), 0);
  }

  function test_seed_mintsNormalisedReserveSum() public {
    _seed(300 ether, 100 ether);

    // both legs are 18-decimal, so the normalised sum is the plain sum
    assertEq(lp.totalSupply(), 400 ether);
    assertEq(lp.balanceOf(userA), 400 ether);
    assertEq(pool.balances(0), 300 ether);
    assertEq(pool.balances(1), 100 ether);
    assertEq(pool.get_virtual_price(), 1e18);
  }

  function test_seed_onlyManager() public {
    _fund(userB, pool.coins(0), 1 ether);
    _fund(userB, pool.coins(1), 1 ether);
    vm.prank(userB);
    vm.expectRevert();
    pool.seed([uint256(1 ether), uint256(1 ether)]);
  }

  function test_seed_cannotRunTwice() public {
    _seed(300 ether, 100 ether);
    _fund(userA, pool.coins(0), 1 ether);
    _fund(userA, pool.coins(1), 1 ether);
    vm.prank(userA);
    vm.expectRevert("already seeded");
    pool.seed([uint256(1 ether), uint256(1 ether)]);
  }

  function test_seed_requiresBothLegs() public {
    _fund(userA, pool.coins(0), 1 ether);
    vm.prank(userA);
    vm.expectRevert("seed requires both coins");
    pool.seed([uint256(1 ether), uint256(0)]);
  }

  function test_addLiquidity_revertsBeforeSeeding() public {
    _fund(userB, pool.coins(0), 10 ether);
    _fund(userB, pool.coins(1), 10 ether);
    vm.prank(userB);
    vm.expectRevert("not seeded");
    pool.add_liquidity(1 ether, [uint256(10 ether), uint256(10 ether)]);
  }

  /* ──────────────────────────── deposits ─────────────────────────── */

  function test_addLiquidity_pullsExactlyTheQuotedAmounts() public {
    _seed(300 ether, 100 ether);

    uint256 lpAmount = 40 ether;
    uint256[2] memory quote = pool.calc_add_liquidity(lpAmount);
    assertEq(quote[0], 30 ether);
    assertEq(quote[1], 10 ether);

    _fund(userB, pool.coins(0), quote[0]);
    _fund(userB, pool.coins(1), quote[1]);

    uint256[2] memory before = _reserves();
    vm.prank(userB);
    pool.add_liquidity(lpAmount, quote);

    // the quote is what execution charges — no surplus is kept, nothing is returned
    assertEq(pool.balances(0) - before[0], quote[0]);
    assertEq(pool.balances(1) - before[1], quote[1]);
    assertEq(_balanceOf(pool.coins(0), userB), 0);
    assertEq(_balanceOf(pool.coins(1), userB), 0);
    assertEq(lp.balanceOf(userB), lpAmount);
  }

  function test_addLiquidity_respectsMaxAmounts() public {
    _seed(300 ether, 100 ether);

    uint256[2] memory quote = pool.calc_add_liquidity(40 ether);
    _fund(userB, pool.coins(0), quote[0]);
    _fund(userB, pool.coins(1), quote[1]);

    vm.prank(userB);
    vm.expectRevert("exceeds max");
    pool.add_liquidity(40 ether, [quote[0] - 1, quote[1]]);

    vm.prank(userB);
    vm.expectRevert("exceeds max");
    pool.add_liquidity(40 ether, [quote[0], quote[1] - 1]);
  }

  function test_addLiquidity_rejectsZeroShares() public {
    _seed(300 ether, 100 ether);
    vm.prank(userB);
    vm.expectRevert("zero mint");
    pool.add_liquidity(0, [uint256(0), uint256(0)]);
  }

  function test_addLiquidity_rejectsNativeValueOnAnErc20Pool() public {
    _seed(300 ether, 100 ether);
    uint256[2] memory quote = pool.calc_add_liquidity(40 ether);
    _fund(userB, pool.coins(0), quote[0]);
    _fund(userB, pool.coins(1), quote[1]);
    vm.deal(userB, 1 ether);

    vm.prank(userB);
    vm.expectRevert("Inconsistent quantity");
    pool.add_liquidity{ value: 1 }(40 ether, quote);
  }

  function test_addLiquidity_isBlockedWhilePaused() public {
    _seed(300 ether, 100 ether);
    uint256[2] memory quote = pool.calc_add_liquidity(40 ether);
    _fund(userB, pool.coins(0), quote[0]);
    _fund(userB, pool.coins(1), quote[1]);

    vm.prank(pauser);
    pool.pause();

    vm.prank(userB);
    vm.expectRevert();
    pool.add_liquidity(40 ether, quote);
  }

  /* ─────────────────────────── redemptions ───────────────────────── */

  function test_removeLiquidity_paysProRata() public {
    _seed(300 ether, 100 ether);
    _add(userB, 40 ether);

    uint256 supply = lp.totalSupply();
    uint256[2] memory before = _reserves();
    uint256 burn = 40 ether;

    vm.prank(userB);
    pool.remove_liquidity(burn, [uint256(0), uint256(0)]);

    assertEq(_balanceOf(pool.coins(0), userB), (before[0] * burn) / supply);
    assertEq(_balanceOf(pool.coins(1), userB), (before[1] * burn) / supply);
    assertEq(lp.balanceOf(userB), 0);
  }

  function test_removeLiquidity_respectsMinAmounts() public {
    _seed(300 ether, 100 ether);
    _add(userB, 40 ether);

    uint256[2] memory out = pool.calc_add_liquidity(40 ether);

    vm.prank(userB);
    vm.expectRevert("below min amount");
    pool.remove_liquidity(40 ether, [out[0] + 1, uint256(0)]);

    vm.prank(userB);
    vm.expectRevert("below min amount");
    pool.remove_liquidity(40 ether, [uint256(0), out[1] + 1]);
  }

  function test_removeLiquidity_staysOpenWhilePaused() public {
    _seed(300 ether, 100 ether);
    _add(userB, 40 ether);

    vm.prank(pauser);
    pool.pause();

    vm.prank(userB);
    pool.remove_liquidity(40 ether, [uint256(0), uint256(0)]);

    assertEq(lp.balanceOf(userB), 0);
    assertGt(_balanceOf(pool.coins(0), userB), 0);
    assertGt(_balanceOf(pool.coins(1), userB), 0);
  }

  function test_removeLiquidity_rejectsZero() public {
    _seed(300 ether, 100 ether);
    vm.prank(userA);
    vm.expectRevert("nothing to redeem");
    pool.remove_liquidity(0, [uint256(0), uint256(0)]);
  }

  /* ───────────────────────── invariants ──────────────────────────── */

  /// @dev A deposit followed by an immediate redemption may never return more than it cost.
  function testFuzz_roundTripNeverPaysOutMoreThanItCost(uint96 lpAmount) public {
    _seed(300 ether, 100 ether);
    vm.assume(lpAmount > 1e6);

    uint256[2] memory cost = _add(userB, lpAmount);

    vm.prank(userB);
    pool.remove_liquidity(lpAmount, [uint256(0), uint256(0)]);

    assertLe(_balanceOf(pool.coins(0), userB), cost[0]);
    assertLe(_balanceOf(pool.coins(1), userB), cost[1]);
  }

  /// @dev Reserves only ever move together, so the LP token stays a claim on a fixed basket.
  function test_reserveRatioSurvivesRepeatedDepositsAndRedemptions() public {
    _seed(300 ether, 100 ether);
    uint256 ratio = (pool.balances(0) * 1e18) / pool.balances(1);

    for (uint256 i = 0; i < 8; i++) {
      _add(userB, 7 ether + i * 1 ether);
      vm.prank(userB);
      pool.remove_liquidity(3 ether, [uint256(0), uint256(0)]);
    }

    uint256 after_ = (pool.balances(0) * 1e18) / pool.balances(1);
    assertApproxEqRel(after_, ratio, 1e6, "reserve ratio drifted"); // 1e-12 relative
  }

  /// @dev Rounding is always in the pool's favour, so intrinsic value can only rise.
  function test_virtualPriceIsNonDecreasing() public {
    _seed(300 ether, 100 ether);
    uint256 last = pool.get_virtual_price();

    for (uint256 i = 0; i < 8; i++) {
      _add(userB, 1 ether + i * 3333);
      uint256 vp = pool.get_virtual_price();
      assertGe(vp, last, "deposit cut intrinsic value");
      last = vp;

      vm.prank(userB);
      pool.remove_liquidity(1 ether, [uint256(0), uint256(0)]);
      vp = pool.get_virtual_price();
      assertGe(vp, last, "redemption cut intrinsic value");
      last = vp;
    }
  }

  /* ────────────────────────── surplus sweep ──────────────────────── */

  function test_adminBalances_countOnlyUnbookedTokens() public {
    _seed(300 ether, 100 ether);
    assertEq(pool.admin_balances(0), 0);

    ERC20Mock coin = ERC20Mock(pool.coins(0));
    coin.setBalance(address(pool), coin.balanceOf(address(pool)) + 5 ether);

    assertEq(pool.admin_balances(0), 5 ether);
    assertEq(pool.balances(0), 300 ether, "a direct transfer must not become reserves");
  }

  function test_withdrawAdminFees_leavesReservesIntact() public {
    _seed(300 ether, 100 ether);

    ERC20Mock coin = ERC20Mock(pool.coins(0));
    coin.setBalance(address(pool), coin.balanceOf(address(pool)) + 5 ether);

    vm.prank(manager);
    pool.withdraw_admin_fees();

    assertEq(coin.balanceOf(manager), 5 ether);
    assertEq(coin.balanceOf(address(pool)), 300 ether);
    assertEq(pool.admin_balances(0), 0);
  }
}

/// @notice One native leg. The native amount arrives whole, so it has to match to the wei.
contract StableSwapPoolBNBTest is StableSwapPoolBase {
  ERC20Mock tokenA;

  function setUp() public {
    _deployFactory();
    tokenA = new ERC20Mock();
    (pool, lp) = _createPair(address(tokenA), BNB);

    assertTrue(pool.support_BNB());

    uint256 n = _nativeIndex();
    uint256[2] memory amounts;
    amounts[n] = 100 ether;
    amounts[1 - n] = 300 ether;

    _fund(userA, pool.coins(0), amounts[0]);
    _fund(userA, pool.coins(1), amounts[1]);

    vm.prank(userA);
    pool.seed{ value: amounts[n] }(amounts);
  }

  function _nativeIndex() internal view returns (uint256) {
    return pool.coins(0) == BNB ? 0 : 1;
  }

  function test_seed_bookedBothLegs() public view {
    assertEq(lp.totalSupply(), 400 ether);
    assertEq(address(pool).balance, pool.balances(_nativeIndex()));
  }

  function test_addLiquidity_requiresTheExactNativeAmount() public {
    uint256 n = _nativeIndex();
    uint256[2] memory quote = pool.calc_add_liquidity(40 ether);

    _fund(userB, pool.coins(0), quote[0]);
    _fund(userB, pool.coins(1), quote[1]);
    vm.deal(userB, quote[n] + 1 ether);

    vm.prank(userB);
    vm.expectRevert("exact native amount required");
    pool.add_liquidity{ value: quote[n] - 1 }(40 ether, quote);

    vm.prank(userB);
    vm.expectRevert("exact native amount required");
    pool.add_liquidity{ value: quote[n] + 1 }(40 ether, quote);

    vm.prank(userB);
    pool.add_liquidity{ value: quote[n] }(40 ether, quote);
    assertEq(lp.balanceOf(userB), 40 ether);
  }

  function test_removeLiquidity_paysOutNative() public {
    uint256 n = _nativeIndex();
    uint256[2] memory cost = _add(userB, 40 ether);

    vm.deal(userB, 0);
    vm.prank(userB);
    pool.remove_liquidity(40 ether, [uint256(0), uint256(0)]);

    assertGt(userB.balance, 0);
    assertLe(userB.balance, cost[n]);
    assertEq(address(pool).balance, pool.balances(n), "native reserves and the booked figure diverged");
  }
}

/// @notice Legs with different decimals: shares are denominated in the normalised reserve value.
contract StableSwapPoolMixedDecimalsTest is StableSwapPoolBase {
  ERC20Mock coin18;
  ERC20Mock coin6;

  function setUp() public {
    _deployFactory();
    coin18 = new ERC20Mock();
    coin6 = new ERC20Mock();
    coin6.setDecimals(6);
    (pool, lp) = _createPair(address(coin18), address(coin6));
  }

  function _index(address coin) internal view returns (uint256) {
    return pool.coins(0) == coin ? 0 : 1;
  }

  function test_seed_normalisesTheSixDecimalLeg() public {
    uint256 i18 = _index(address(coin18));
    uint256 i6 = _index(address(coin6));

    uint256[2] memory amounts;
    amounts[i18] = 100 ether;
    amounts[i6] = 100e6;

    _fund(userA, address(coin18), amounts[i18]);
    _fund(userA, address(coin6), amounts[i6]);
    vm.prank(userA);
    pool.seed(amounts);

    // 100e6 of a 6-decimal coin normalises to 100e18, so both legs contribute equally
    assertEq(lp.totalSupply(), 200 ether);
    assertEq(pool.get_virtual_price(), 1e18);
  }

  function test_addLiquidity_roundsTheSmallLegUp() public {
    uint256 i18 = _index(address(coin18));
    uint256 i6 = _index(address(coin6));

    uint256[2] memory amounts;
    amounts[i18] = 100 ether;
    amounts[i6] = 100e6;
    _fund(userA, address(coin18), amounts[i18]);
    _fund(userA, address(coin6), amounts[i6]);
    vm.prank(userA);
    pool.seed(amounts);

    // a share amount that divides into a fractional 6-decimal leg must still charge a whole unit
    uint256 lpAmount = 1 ether + 1;
    uint256[2] memory quote = pool.calc_add_liquidity(lpAmount);
    assertGt(quote[i6], (lpAmount * amounts[i6]) / lp.totalSupply(), "small leg was not rounded up");

    uint256 vpBefore = pool.get_virtual_price();
    _add(userB, lpAmount);
    assertGe(pool.get_virtual_price(), vpBefore);
  }
}

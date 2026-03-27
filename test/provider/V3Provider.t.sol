// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { V3Provider } from "../../src/provider/V3Provider.sol";
import { IUniswapV3Pool } from "../../src/provider/interfaces/IUniswapV3Pool.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TokenConfig, IOracle } from "moolah/interfaces/IOracle.sol";
import { SlisBNBxMinter, ISlisBNBx } from "../../src/utils/SlisBNBxMinter.sol";

/// @dev Helper that executes a direct pool swap and satisfies the PancakeSwap V3 callback.
contract PoolSwapper {
  // MIN / MAX sqrt ratios from TickMath (ticks ±887272)
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  /// @notice Swap tokenIn → tokenOut by selling `amountIn` worth of tokenIn.
  ///         zeroForOne = true  → token0 in, token1 out (price moves down)
  ///         zeroForOne = false → token1 in, token0 out (price moves up)
  function swapExactIn(address pool, bool zeroForOne, uint256 amountIn) external {
    uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool));
  }

  /// @dev PancakeSwap V3 swap callback — pay whatever the pool pulled.
  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    address pool = abi.decode(data, (address));
    if (amount0Delta > 0) IERC20(IUniswapV3Pool(pool).token0()).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(IUniswapV3Pool(pool).token1()).transfer(msg.sender, uint256(amount1Delta));
  }
}

contract V3ProviderTest is Test {
  using MarketParamsLib for MarketParams;

  /* ─────────────────── PancakeSwap V3 BSC mainnet ─────────────────── */
  address constant POOL = 0x4141325bAc36aFFe9Db165e854982230a14e6d48; // USDC/WBNB
  address constant NPM = 0x7b8A01B39D58278b5DE7e48c8449c9f4F5170613;
  uint24 constant FEE = 100;

  /* ───────────────────────────── tokens ───────────────────────────── */
  address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // token0
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // token1

  /* ──────────────────────── Moolah ecosystem ──────────────────────── */
  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint32 constant TWAP_PERIOD = 1800; // 30 minutes
  uint256 constant LLTV = 70 * 1e16;

  /* ───────────────────────── test contracts ───────────────────────── */
  Moolah moolah;
  V3Provider provider;
  MarketParams marketParams;
  Id marketId;

  /* ───────────────────────── test accounts ────────────────────────── */
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  /* ────────────────────────────── setUp ───────────────────────────── */

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    // Upgrade Moolah to the latest local implementation.
    address newImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Derive initial tick range from the live pool.
    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 tickLower = currentTick - 500;
    int24 tickUpper = currentTick + 500;

    // Deploy V3Provider (implementation + UUPS proxy).
    V3Provider impl = new V3Provider(MOOLAH_PROXY, NPM, USDC, WBNB, FEE, TWAP_PERIOD);
    bytes memory initData = abi.encodeCall(
      V3Provider.initialize,
      (admin, manager, bot, RESILIENT_ORACLE, tickLower, tickUpper, "V3Provider USDC/WBNB", "v3LP-USDC-WBNB")
    );
    provider = V3Provider(payable(new ERC1967Proxy(address(impl), initData)));

    // Build Moolah market: collateral = provider shares, oracle = provider.
    marketParams = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(provider),
      irm: IRM,
      lltv: LLTV
    });
    marketId = marketParams.id();

    // Create market and register V3Provider as the Moolah provider.
    vm.prank(OPERATOR);
    moolah.createMarket(marketParams);

    vm.prank(MANAGER_ADDR);
    moolah.setProvider(marketId, address(provider), true);

    // Seed market with lisUSD so borrow tests can succeed.
    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");
  }

  /* ────────────────────────── helper fns ─────────────────────────── */

  function _deposit(
    address _user,
    uint256 amount0,
    uint256 amount1
  ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(USDC, _user, amount0);
    deal(WBNB, _user, amount1);
    // Derive tight min amounts (0.1% slippage) from previewDeposit so that we
    // never bypass the slippage guard with zeros.
    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;
    vm.startPrank(_user);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(marketParams, amount0, amount1, min0, min1, _user);
    vm.stopPrank();
  }

  function _collateral(address _user) internal view returns (uint256) {
    (, , uint256 col) = moolah.position(marketId, _user);
    return col;
  }

  /* ────────────────────────── test cases ─────────────────────────── */

  function test_initialize() public view {
    assertEq(provider.TOKEN0(), USDC);
    assertEq(provider.TOKEN1(), WBNB);
    assertEq(provider.FEE(), FEE);
    assertEq(provider.POOL(), POOL);
    assertEq(address(provider.MOOLAH()), MOOLAH_PROXY);
    assertEq(address(provider.POSITION_MANAGER()), NPM);
    assertEq(provider.resilientOracle(), RESILIENT_ORACLE);
    assertEq(provider.TWAP_PERIOD(), TWAP_PERIOD);
    assertTrue(provider.hasRole(provider.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(provider.hasRole(provider.MANAGER(), manager));
    assertTrue(provider.hasRole(provider.BOT(), bot));
    // BOT role admin is MANAGER
    assertEq(provider.getRoleAdmin(provider.BOT()), provider.MANAGER());
  }

  function test_deposit_firstDeposit() public {
    uint256 amount0 = 1_000 ether; // USDC
    uint256 amount1 = 3 ether; // WBNB

    (uint256 shares, uint256 used0, uint256 used1) = _deposit(user, amount0, amount1);

    assertGt(shares, 0, "should mint shares");
    assertGt(used0 + used1, 0, "should consume tokens");

    // Collateral position in Moolah equals shares minted.
    assertEq(_collateral(user), shares, "Moolah collateral should equal shares");

    // Shares are held by Moolah, not user.
    assertEq(provider.balanceOf(user), 0, "user should hold no shares directly");
    assertEq(provider.balanceOf(MOOLAH_PROXY), shares, "Moolah should hold shares");

    // Unused tokens refunded to caller.
    // USDC refunded as ERC-20; WBNB (TOKEN1 = WRAPPED_NATIVE) refunded as native BNB.
    assertEq(IERC20(USDC).balanceOf(user), amount0 - used0);
    assertEq(user.balance, amount1 - used1);
  }

  function test_deposit_secondDeposit_sharesProportional() public {
    _deposit(user, 1_000 ether, 3 ether);
    uint256 sharesAfterFirst = _collateral(user);

    (uint256 shares2, , ) = _deposit(user2, 2_000 ether, 6 ether);

    // Second depositor contributes roughly twice as much — shares should be ~2x.
    assertApproxEqRel(shares2, sharesAfterFirst * 2, 0.01e18, "second deposit shares should be ~2x");
  }

  function test_withdraw_fullWithdrawal() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    uint256 usdcBefore = IERC20(USDC).balanceOf(user);
    uint256 bnbBefore = user.balance; // WBNB (TOKEN1) is unwrapped to native BNB on withdrawal

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, min0, min1, user, user);

    // Collateral cleared.
    assertEq(_collateral(user), 0, "collateral should be zero after full withdrawal");

    // Tokens returned.
    assertGt(out0 + out1, 0, "should receive tokens back");
    assertEq(IERC20(USDC).balanceOf(user), usdcBefore + out0);
    assertEq(user.balance, bnbBefore + out1); // WBNB unwrapped to BNB
  }

  function test_withdraw_partialWithdrawal() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares / 2);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(user);
    provider.withdraw(marketParams, shares / 2, min0, min1, user, user);

    assertApproxEqAbs(_collateral(user), shares / 2, 1, "half collateral should remain");
  }

  function test_withdraw_revertsIfUnauthorized() public {
    _deposit(user, 1_000 ether, 3 ether);
    uint256 shares = _collateral(user);

    // user2 cannot withdraw on behalf of user without authorization.
    // The revert fires on the auth check before min amounts are evaluated; use 1,1.
    vm.prank(user2);
    vm.expectRevert("unauthorized");
    provider.withdraw(marketParams, shares, 1, 1, user, user2);
  }

  function test_redeemShares_byLiquidator() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    address liquidator = makeAddr("liquidator");

    // Simulate Moolah transferring shares to liquidator during liquidation.
    // (transfer is restricted to Moolah — prank as Moolah to move shares)
    vm.prank(MOOLAH_PROXY);
    provider.transfer(liquidator, shares);

    assertEq(provider.balanceOf(liquidator), shares);

    uint256 usdcBefore = IERC20(USDC).balanceOf(liquidator);
    uint256 bnbBefore = liquidator.balance; // WBNB (TOKEN1) is unwrapped to native BNB

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(liquidator);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, min0, min1, liquidator);

    assertEq(provider.balanceOf(liquidator), 0, "shares should be burned");
    assertGt(out0 + out1, 0, "liquidator should receive tokens");
    assertEq(IERC20(USDC).balanceOf(liquidator), usdcBefore + out0);
    assertEq(liquidator.balance, bnbBefore + out1); // WBNB unwrapped to BNB
  }

  function test_transferRestriction_directTransferReverts() public {
    _deposit(user, 1_000 ether, 3 ether);

    vm.prank(user);
    vm.expectRevert("only moolah");
    provider.transfer(user2, 1);
  }

  function test_transferRestriction_transferFromReverts() public {
    _deposit(user, 1_000 ether, 3 ether);

    vm.prank(user);
    vm.expectRevert("only moolah");
    provider.transferFrom(MOOLAH_PROXY, user2, 1);
  }

  function test_rebalance_onlyBot() public {
    _deposit(user, 1_000 ether, 3 ether);

    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 newLower = currentTick - 1000;
    int24 newUpper = currentTick + 1000;

    // manager cannot rebalance — revert fires on role check before amounts matter.
    vm.prank(manager);
    vm.expectRevert();
    provider.rebalance(newLower, newUpper, 1, 1, 1, 1);

    // bot can rebalance — pass full available amounts so pool picks optimal ratio.
    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    uint256 min0 = (total0 * 999) / 1000;
    uint256 min1 = (total1 * 999) / 1000;
    vm.prank(bot);
    provider.rebalance(newLower, newUpper, min0, min1, total0, total1);

    assertEq(provider.tickLower(), newLower);
    assertEq(provider.tickUpper(), newUpper);
  }

  function test_rebalance_liquidity_preserved() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();

    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    uint256 min0 = (total0 * 999) / 1000;
    uint256 min1 = (total1 * 999) / 1000;
    vm.prank(bot);
    provider.rebalance(currentTick - 1000, currentTick + 1000, min0, min1, total0, total1);

    // Share count is unchanged after rebalance.
    assertEq(_collateral(user), shares, "shares should be unchanged after rebalance");

    // Total amounts should be roughly preserved (small dust from ratio mismatch is acceptable).
    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueBefore = total0Before + total1Before;
    uint256 valueAfter = total0After + total1After;
    assertApproxEqRel(valueAfter, valueBefore, 0.02e18, "total value should be preserved within 2%");
  }

  function test_peek_zeroBeforeDeposit() public view {
    assertEq(provider.peek(address(provider)), 0, "price should be 0 with no deposits");
  }

  function test_peek_nonZeroAfterDeposit() public {
    _deposit(user, 1_000 ether, 3 ether);

    uint256 price = provider.peek(address(provider));
    assertGt(price, 0, "share price should be non-zero after deposit");
  }

  function test_getTwapTick_nearCurrentTick() public view {
    int24 twapTick = provider.getTwapTick();
    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();

    // TWAP tick should be within a reasonable distance of the current tick.
    int256 diff = int256(currentTick) - int256(twapTick);
    if (diff < 0) diff = -diff;
    assertLt(diff, 500, "TWAP tick should be near current tick");
  }

  function test_getTotalAmounts_nonZeroAfterDeposit() public {
    _deposit(user, 1_000 ether, 3 ether);

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertGt(total0 + total1, 0, "total amounts should be non-zero after deposit");
  }

  function test_compoundFees_shareValueIncreasesOverTime() public {
    // mock USDC price
    vm.mockCall(
      RESILIENT_ORACLE,
      abi.encodeWithSelector(IOracle.peek.selector, USDC),
      abi.encode(1e8) // $1 with 8 decimals
    );

    // mock WBNB price; $700
    vm.mockCall(
      RESILIENT_ORACLE,
      abi.encodeWithSelector(IOracle.peek.selector, WBNB),
      abi.encode(700 * 1e8) // $700 with 8 decimals
    );

    // Stabilise the TWAP tick across the vm.warp by mocking pool.observe to always
    // return tick cumulatives consistent with the current slot0 tick.  Without this,
    // the 7-day warp shifts the TWAP window from real BSC history to pure extrapolation,
    // producing a spurious ~0.3% price delta that has nothing to do with fee compounding.
    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int56[] memory tickCumulatives = new int56[](2);
    tickCumulatives[0] = 0;
    tickCumulatives[1] = int56(currentTick) * int56(uint56(TWAP_PERIOD));
    uint160[] memory secondsPerLiq = new uint160[](2);
    vm.mockCall(
      POOL,
      abi.encodeWithSelector(IUniswapV3Pool.observe.selector),
      abi.encode(tickCumulatives, secondsPerLiq)
    );

    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    uint256 priceBefore = provider.peek(address(provider));

    // Simulate time passing and swap activity accumulating fees by warping forward.
    vm.warp(block.timestamp + 7 days);

    // A second deposit triggers _collectAndCompound internally.
    _deposit(user2, 1_000 ether, 3 ether);

    uint256 priceAfter = provider.peek(address(provider));

    // Share price should be >= before (fees compounded, no value destroyed).
    assertGe(priceAfter, priceBefore, "share price should not decrease after compounding");

    // user's collateral share count is unchanged.
    assertEq(_collateral(user), shares);
  }

  /// @dev Helper: deposit with explicit min amounts (bypasses _deposit which passes zeros).
  function _depositWithMin(
    address _user,
    uint256 amount0,
    uint256 amount1,
    uint256 min0,
    uint256 min1
  ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(USDC, _user, amount0);
    deal(WBNB, _user, amount1);
    vm.startPrank(_user);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(marketParams, amount0, amount1, min0, min1, _user);
    vm.stopPrank();
  }

  /* ──────────────── previewDeposit tests ─────────────────────────── */

  function test_previewDeposit_amountsMatchActual() public {
    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    (uint128 liquidity, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);

    assertGt(liquidity, 0, "liquidity should be non-zero");
    // Both preview amounts must be within the desired amounts.
    assertLe(exp0, amount0, "exp0 must not exceed desired");
    assertLe(exp1, amount1, "exp1 must not exceed desired");
    assertGt(exp0 + exp1, 0, "at least one token must be consumed");

    // Actual deposit should consume within 1 wei of what previewDeposit predicted
    // (NPM uses the same math with possible ±1 rounding differences).
    uint256 min0 = exp0 > 0 ? exp0 - 1 : 0;
    uint256 min1 = exp1 > 0 ? exp1 - 1 : 0;
    (, uint256 used0, uint256 used1) = _depositWithMin(user, amount0, amount1, min0, min1);

    assertApproxEqAbs(used0, exp0, 1, "used0 should match preview within 1 wei");
    assertApproxEqAbs(used1, exp1, 1, "used1 should match preview within 1 wei");
  }

  function test_previewDeposit_derivedMinAmounts_succeed() public {
    uint256 amount0 = 5_000 ether;
    uint256 amount1 = 15 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);

    // Apply 0.5% slippage tolerance.
    uint256 min0 = (exp0 * 995) / 1000;
    uint256 min1 = (exp1 * 995) / 1000;

    (uint256 shares, uint256 used0, uint256 used1) = _depositWithMin(user, amount0, amount1, min0, min1);

    assertGt(shares, 0, "should mint shares");
    assertGe(used0, min0, "used0 >= min0");
    assertGe(used1, min1, "used1 >= min1");
  }

  function test_previewDeposit_priceBelowRange_onlyToken0() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);

    // Position is fully USDC — only token0 consumed, token1 = 0.
    assertGt(exp0, 0, "expected token0 consumed when price below range");
    assertEq(exp1, 0, "expected no token1 consumed when price below range");
  }

  function test_previewDeposit_priceAboveRange_onlyToken1() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);

    // Position is fully WBNB — only token1 consumed, token0 = 0.
    assertEq(exp0, 0, "expected no token0 consumed when price above range");
    assertGt(exp1, 0, "expected token1 consumed when price above range");
  }

  function test_previewDeposit_secondDeposit_matchesActual() public {
    // Seed an initial position so the second deposit goes through increaseLiquidity.
    _deposit(user, 1_000 ether, 3 ether);

    uint256 amount0 = 2_000 ether;
    uint256 amount1 = 6 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);

    uint256 min0 = exp0 > 0 ? exp0 - 1 : 0;
    uint256 min1 = exp1 > 0 ? exp1 - 1 : 0;
    (, uint256 used0, uint256 used1) = _depositWithMin(user2, amount0, amount1, min0, min1);

    assertApproxEqAbs(used0, exp0, 1, "used0 should match preview within 1 wei on second deposit");
    assertApproxEqAbs(used1, exp1, 1, "used1 should match preview within 1 wei on second deposit");
  }

  /* ──────────────── previewRedeem tests ──────────────────────────── */

  function test_previewRedeem_zeroBeforeDeposit() public view {
    (uint256 amount0, uint256 amount1) = provider.previewRedeem(1 ether);
    assertEq(amount0, 0, "should return 0 when no position exists");
    assertEq(amount1, 0, "should return 0 when no position exists");
  }

  function test_previewRedeem_matchesActualWithdraw() public {
    // Price is inside the tick range: preview predicts both tokens, withdraw returns both.
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    (, int24 currentTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    assertGt(currentTick, provider.tickLower(), "price should be above tickLower");
    assertLt(currentTick, provider.tickUpper(), "price should be below tickUpper");

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    assertGt(exp0, 0, "previewRedeem should predict token0 in-range");
    assertGt(exp1, 0, "previewRedeem should predict token1 in-range");

    uint256 min0 = exp0 - 1;
    uint256 min1 = exp1 - 1;

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, min0, min1, user, user);

    assertApproxEqAbs(out0, exp0, 1, "out0 should match preview within 1 wei");
    assertApproxEqAbs(out1, exp1, 1, "out1 should match preview within 1 wei");
    assertGt(out0, 0, "should receive token0 when withdrawing in-range");
    assertGt(out1, 0, "should receive token1 when withdrawing in-range");
  }

  function test_previewRedeem_matchesActualRedeemShares() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    vm.prank(MOOLAH_PROXY);
    provider.transfer(user2, shares);

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);

    uint256 min0 = exp0 > 0 ? exp0 - 1 : 0;
    uint256 min1 = exp1 > 0 ? exp1 - 1 : 0;

    vm.prank(user2);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, min0, min1, user2);

    assertApproxEqAbs(out0, exp0, 1, "out0 should match preview within 1 wei");
    assertApproxEqAbs(out1, exp1, 1, "out1 should match preview within 1 wei");
  }

  function test_previewRedeem_partialShares_proportional() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    (uint256 fullExp0, uint256 fullExp1) = provider.previewRedeem(shares);
    (uint256 halfExp0, uint256 halfExp1) = provider.previewRedeem(shares / 2);

    // Half the shares should yield approximately half the tokens.
    assertApproxEqRel(halfExp0, fullExp0 / 2, 0.001e18, "half shares ~half token0");
    assertApproxEqRel(halfExp1, fullExp1 / 2, 0.001e18, "half shares ~half token1");
  }

  function test_previewRedeem_priceBelowRange_onlyToken0() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    assertGt(exp0, 0, "should return token0 when price below range");
    assertEq(exp1, 0, "should return no token1 when price below range");
  }

  function test_previewRedeem_priceAboveRange_onlyToken1() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    assertEq(exp0, 0, "should return no token0 when price above range");
    assertGt(exp1, 0, "should return token1 when price above range");
  }

  function test_previewRedeem_derivedMinAmounts_succeed() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);

    // Apply 0.5% slippage tolerance.
    uint256 min0 = (exp0 * 995) / 1000;
    uint256 min1 = (exp1 * 995) / 1000;

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, min0, min1, user, user);

    assertGe(out0, min0, "out0 >= min0");
    assertGe(out1, min1, "out1 >= min1");
  }

  function test_deposit_minAmount0_tooHigh_reverts_firstDeposit() public {
    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    // min0 far exceeds what NPM can place — should revert from NPM slippage check.
    deal(USDC, user, amount0);
    deal(WBNB, user, amount1);
    vm.startPrank(user);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, amount0 * 2, 0, user);
    vm.stopPrank();
  }

  function test_deposit_minAmount1_tooHigh_reverts_firstDeposit() public {
    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    deal(USDC, user, amount0);
    deal(WBNB, user, amount1);
    vm.startPrank(user);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, 0, amount1 * 2, user);
    vm.stopPrank();
  }

  function test_deposit_minAmount0_tooHigh_reverts_secondDeposit() public {
    _deposit(user, 1_000 ether, 3 ether);

    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    deal(USDC, user2, amount0);
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, amount0 * 2, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_minAmount1_tooHigh_reverts_secondDeposit() public {
    _deposit(user, 1_000 ether, 3 ether);

    uint256 amount0 = 1_000 ether;
    uint256 amount1 = 3 ether;

    deal(USDC, user2, amount0);
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(USDC).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, 0, amount1 * 2, user2);
    vm.stopPrank();
  }

  /* ──────────── one-sided deposit tests ──────────────────────────── */

  // When the price is in-range both tokens are required to add liquidity.
  // Supplying only one token yields 0 liquidity → "zero shares" revert.

  function test_deposit_oneSided_token0Only_inRange_reverts() public {
    // Price is in-range: token0 alone yields 0 liquidity → "zero shares".
    // Pass min=0 so NPM doesn't revert first; our guard fires instead.
    deal(USDC, user, 10_000 ether);
    vm.startPrank(user);
    IERC20(USDC).approve(address(provider), 10_000 ether);
    vm.expectRevert("zero liquidity");
    provider.deposit(marketParams, 10_000 ether, 0, 0, 0, user);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token1Only_inRange_reverts() public {
    // Price is in-range: token1 alone yields 0 liquidity → "zero shares".
    deal(WBNB, user, 30 ether);
    vm.startPrank(user);
    IERC20(WBNB).approve(address(provider), 30 ether);
    vm.expectRevert("zero liquidity");
    provider.deposit(marketParams, 0, 30 ether, 0, 0, user);
    vm.stopPrank();
  }

  // When the price is outside the range only one token is valid.
  // Supplying the correct token succeeds; supplying the wrong token reverts.

  function test_deposit_oneSided_token0Only_belowRange_succeeds() public {
    // Seed a position first so rebalance can move ticks.
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    // Price below tickLower: only token0 (USDC) is accepted.
    uint256 amount0 = 5_000 ether;
    deal(USDC, user2, amount0);
    vm.startPrank(user2);
    IERC20(USDC).approve(address(provider), amount0);
    (, uint256 exp0, ) = provider.previewDeposit(amount0, 0);
    uint256 min0 = (exp0 * 999) / 1000;
    (uint256 shares, uint256 used0, uint256 used1) = provider.deposit(marketParams, amount0, 0, min0, 0, user2);
    vm.stopPrank();

    assertGt(shares, 0, "should mint shares with token0 only below range");
    assertGt(used0, 0, "should consume token0");
    assertEq(used1, 0, "should not consume token1");
  }

  function test_deposit_oneSided_token1Only_belowRange_reverts() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    // Price below range: token1 alone yields 0 liquidity → "zero shares".
    deal(WBNB, user2, 30 ether);
    vm.startPrank(user2);
    IERC20(WBNB).approve(address(provider), 30 ether);
    vm.expectRevert("zero liquidity");
    provider.deposit(marketParams, 0, 30 ether, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token1Only_aboveRange_succeeds() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    // Price above tickUpper: only token1 (WBNB) is accepted.
    uint256 amount1 = 15 ether;
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(WBNB).approve(address(provider), amount1);
    (, , uint256 exp1) = provider.previewDeposit(0, amount1);
    uint256 min1 = (exp1 * 999) / 1000;
    (uint256 shares, uint256 used0, uint256 used1) = provider.deposit(marketParams, 0, amount1, 0, min1, user2);
    vm.stopPrank();

    assertGt(shares, 0, "should mint shares with token1 only above range");
    assertEq(used0, 0, "should not consume token0");
    assertGt(used1, 0, "should consume token1");
  }

  function test_deposit_oneSided_token0Only_aboveRange_reverts() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    // Price above range: token0 alone yields 0 liquidity → "zero shares".
    deal(USDC, user2, 10_000 ether);
    vm.startPrank(user2);
    IERC20(USDC).approve(address(provider), 10_000 ether);
    vm.expectRevert("zero liquidity");
    provider.deposit(marketParams, 10_000 ether, 0, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_revertsWithInvalidCollateralToken() public {
    MarketParams memory badParams = marketParams;
    badParams.collateralToken = USDC;

    deal(USDC, user, 1_000 ether);
    deal(WBNB, user, 3 ether);
    vm.startPrank(user);
    IERC20(USDC).approve(address(provider), 1_000 ether);
    IERC20(WBNB).approve(address(provider), 3 ether);
    vm.expectRevert("invalid collateral token");
    // The revert fires before min amounts are evaluated; use 1,1 for consistency.
    provider.deposit(badParams, 1_000 ether, 3 ether, 1, 1, user);
    vm.stopPrank();
  }

  function test_getTokenConfig() public view {
    TokenConfig memory config = provider.getTokenConfig(address(provider));
    assertEq(config.asset, address(provider));
    assertEq(config.oracles[0], address(provider));
    assertTrue(config.enableFlagsForOracles[0]);
    assertEq(config.oracles[1], address(0));
    assertEq(config.oracles[2], address(0));
  }

  /* ─────────── rebalance after price leaves range (fully USDC) ─────── */

  // Prices: USDC = $1, WBNB = $700 (8-decimal USD)
  uint256 constant USDC_PRICE = 1e8;
  uint256 constant WBNB_PRICE = 700e8;
  // USDC and WBNB are both 18-decimal on BSC.
  uint256 constant TOKEN_DECIMALS = 1e18;

  function _mockOraclePrices() internal {
    vm.mockCall(RESILIENT_ORACLE, abi.encodeWithSelector(IOracle.peek.selector, USDC), abi.encode(USDC_PRICE));
    vm.mockCall(RESILIENT_ORACLE, abi.encodeWithSelector(IOracle.peek.selector, WBNB), abi.encode(WBNB_PRICE));
  }

  /// @dev Compute USD value (8-decimal) from raw token amounts.
  function _valueUSD(uint256 amount0, uint256 amount1) internal pure returns (uint256) {
    return (amount0 * USDC_PRICE) / TOKEN_DECIMALS + (amount1 * WBNB_PRICE) / TOKEN_DECIMALS;
  }

  /// @dev Push pool price below tickLower by swapping a large amount of USDC → WBNB.
  ///      zeroForOne = true (token0 → token1) drives the tick downward.
  ///      When tick < tickLower the V3 position converts entirely to token0 (USDC).
  function _pushPriceBelowRange() internal {
    PoolSwapper swapper = new PoolSwapper();
    uint256 usdcIn = 5_000_000_000 ether; // 5 billion USDC — enough to blow past ±500 ticks
    deal(USDC, address(swapper), usdcIn);
    swapper.swapExactIn(POOL, true, usdcIn);
  }

  function test_rebalance_priceBelowRange_positionFullyUSDC() public {
    _mockOraclePrices();
    _deposit(user, 10_000 ether, 30 ether);

    // Push price below tickLower — position should convert entirely to USDC (token0).
    _pushPriceBelowRange();

    (, int24 tickAfterSwap, , , , , ) = IUniswapV3Pool(POOL).slot0();
    assertLt(tickAfterSwap, provider.tickLower(), "tick should be below tickLower after swap");

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertGt(total0, 0, "should hold USDC");
    assertEq(total1, 0, "position should be fully USDC (token1 == 0) when price is below range");
  }

  function test_rebalance_priceBelowRange_totalValuePreserved() public {
    _mockOraclePrices();
    _deposit(user, 10_000 ether, 30 ether);

    _pushPriceBelowRange();

    // Snapshot USD value before rebalance (position is 100% USDC).
    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();
    uint256 valueBefore = _valueUSD(total0Before, total1Before);
    assertGt(valueBefore, 0, "should have non-zero value before rebalance");

    // Rebalance to a range entirely ABOVE the current (very low) tick so that
    // the entire range is below current price → only token0 (USDC) is needed to mint.
    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 newLower = newTick + 100;
    int24 newUpper = newTick + 600;

    // Position is 100% USDC — only token0 needed for new range (price below it).
    uint256 min0 = (total0Before * 999) / 1000;
    vm.prank(bot);
    provider.rebalance(newLower, newUpper, min0, 0, total0Before, 0);

    assertEq(provider.tickLower(), newLower, "tickLower updated");
    assertEq(provider.tickUpper(), newUpper, "tickUpper updated");

    // Position is still fully USDC (price below new range). All USDC was deployed
    // into the new position; getTotalAmounts captures it via position amounts.
    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueAfter = _valueUSD(total0After, total1After);

    assertApproxEqRel(valueAfter, valueBefore, 0.01e16, "total value should be preserved within 0.01% after rebalance");
  }

  /* ─────────── rebalance after price leaves range (fully WBNB) ──────── */

  /// @dev Push pool price above tickUpper by swapping a large amount of WBNB → USDC.
  ///      zeroForOne = false (token1 → token0) drives the tick upward.
  ///      When tick > tickUpper the V3 position converts entirely to token1 (WBNB).
  function _pushPriceAboveRange() internal {
    PoolSwapper swapper = new PoolSwapper();
    uint256 wbnbIn = 10_000_000 ether; // 10 million WBNB — enough to blow past ±500 ticks
    deal(WBNB, address(swapper), wbnbIn);
    swapper.swapExactIn(POOL, false, wbnbIn);
  }

  function test_rebalance_priceAboveRange_positionFullyWBNB() public {
    _mockOraclePrices();
    _deposit(user, 10_000 ether, 30 ether);

    // Push price above tickUpper — position should convert entirely to WBNB (token1).
    _pushPriceAboveRange();

    (, int24 tickAfterSwap, , , , , ) = IUniswapV3Pool(POOL).slot0();
    assertGt(tickAfterSwap, provider.tickUpper(), "tick should be above tickUpper after swap");

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertEq(total0, 0, "position should be fully WBNB (token0 == 0) when price is above range");
    assertGt(total1, 0, "should hold WBNB");
  }

  function test_rebalance_priceAboveRange_totalValuePreserved() public {
    _mockOraclePrices();
    _deposit(user, 10_000 ether, 30 ether);

    _pushPriceAboveRange();

    // Snapshot USD value before rebalance (position is 100% WBNB).
    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();
    uint256 valueBefore = _valueUSD(total0Before, total1Before);
    assertGt(valueBefore, 0, "should have non-zero value before rebalance");

    // Rebalance to a range entirely BELOW the current (very high) tick so that
    // the entire range is above current price → only token1 (WBNB) is needed to mint.
    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 newLower = newTick - 600;
    int24 newUpper = newTick - 100;

    // Position is 100% WBNB — only token1 needed for new range (price above it).
    uint256 min1 = (total1Before * 999) / 1000;
    vm.prank(bot);
    provider.rebalance(newLower, newUpper, 0, min1, 0, total1Before);

    assertEq(provider.tickLower(), newLower, "tickLower updated");
    assertEq(provider.tickUpper(), newUpper, "tickUpper updated");

    // Position is still fully WBNB (price above new range). All WBNB was deployed
    // into the new position; getTotalAmounts captures it via position amounts.
    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueAfter = _valueUSD(total0After, total1After);

    assertApproxEqRel(valueAfter, valueBefore, 0.01e16, "total value should be preserved within 0.01% after rebalance");
  }

  /* ──────────── minAmount slippage guard tests ────────────────────── */

  /// @dev When price is below range the position is 100% USDC (token0).
  ///      rebalance with minAmount0 = actual USDC held passes; minAmount0 > actual reverts.
  function test_rebalance_priceBelowRange_minAmount0_passes() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    (uint256 total0, ) = provider.getTotalAmounts();
    assertGt(total0, 0, "should hold USDC before rebalance");

    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();

    // minAmount0 = total0 (exact), minAmount1 = 0 (position has no WBNB).
    // amount0Desired = total0, amount1Desired = 0 (reinvest all USDC, no WBNB available).
    vm.prank(bot);
    provider.rebalance(newTick + 100, newTick + 600, total0, 0, total0, 0);

    assertEq(provider.tickLower(), newTick + 100, "tickLower updated");
  }

  function test_rebalance_priceBelowRange_minAmount0_tooHigh_reverts() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    (uint256 total0, ) = provider.getTotalAmounts();

    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();

    // minAmount0 one unit above actual → should revert with NPM slippage check.
    // amount0Desired = total0 (correct available), minAmount0 = total0 + 1 (too tight).
    vm.prank(bot);
    vm.expectRevert();
    provider.rebalance(newTick + 100, newTick + 600, total0 + 1, 0, total0, 0);
  }

  /// @dev When price is above range the position is 100% WBNB (token1).
  ///      rebalance with minAmount1 = actual WBNB held passes; minAmount1 > actual reverts.
  function test_rebalance_priceAboveRange_minAmount1_passes() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    (, uint256 total1) = provider.getTotalAmounts();
    assertGt(total1, 0, "should hold WBNB before rebalance");

    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();

    // minAmount0 = 0 (no USDC), minAmount1 = total1 (exact).
    // amount0Desired = 0, amount1Desired = total1 (reinvest all WBNB).
    vm.prank(bot);
    provider.rebalance(newTick - 600, newTick - 100, 0, total1, 0, total1);

    assertEq(provider.tickUpper(), newTick - 100, "tickUpper updated");
  }

  function test_rebalance_priceAboveRange_minAmount1_tooHigh_reverts() public {
    _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    (, uint256 total1) = provider.getTotalAmounts();

    (, int24 newTick, , , , , ) = IUniswapV3Pool(POOL).slot0();

    // minAmount1 one unit above actual → should revert with NPM slippage check.
    // amount1Desired = total1 (correct available), minAmount1 = total1 + 1 (too tight).
    vm.prank(bot);
    vm.expectRevert();
    provider.rebalance(newTick - 600, newTick - 100, 0, total1 + 1, 0, total1);
  }

  function test_withdraw_minAmount_tooHigh_reverts() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    (uint256 exp0, ) = provider.previewRedeem(shares);

    vm.prank(user);
    vm.expectRevert();
    provider.withdraw(marketParams, shares, exp0 * 2, 1, user, user);
  }

  function test_redeemShares_minAmount_tooHigh_reverts() public {
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    vm.prank(MOOLAH_PROXY);
    provider.transfer(user2, shares);

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    uint256 min0 = (exp0 * 999) / 1000;

    vm.prank(user2);
    vm.expectRevert();
    provider.redeemShares(shares, min0, exp1 * 2, user2);
  }

  /* ──────────── withdraw token composition by price position ─────── */

  function test_withdraw_belowRange_returnsToken0Only() public {
    // When price is below tickLower the entire position is token0.
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);
    _pushPriceBelowRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    assertGt(exp0, 0, "previewRedeem should predict token0 below range");
    assertEq(exp1, 0, "previewRedeem should predict zero token1 below range");

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, (exp0 * 999) / 1000, 0, user, user);

    assertGt(out0, 0, "should receive token0 when price below range");
    assertEq(out1, 0, "should receive no token1 when price below range");
  }

  function test_withdraw_aboveRange_returnsToken1Only() public {
    // When price is above tickUpper the entire position is token1.
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);
    _pushPriceAboveRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    assertEq(exp0, 0, "previewRedeem should predict zero token0 above range");
    assertGt(exp1, 0, "previewRedeem should predict token1 above range");

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, 0, (exp1 * 999) / 1000, user, user);

    assertEq(out0, 0, "should receive no token0 when price above range");
    assertGt(out1, 0, "should receive token1 when price above range");
  }

  function test_withdraw_inRange_cannotForceOneSided_alwaysBoth() public {
    // Even with minAmount1=0, an in-range withdrawal still returns token1.
    // Setting min to 0 disables the floor but does not change what is received.
    (uint256 shares, , ) = _deposit(user, 10_000 ether, 30 ether);

    (uint256 exp0, ) = provider.previewRedeem(shares);

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, (exp0 * 999) / 1000, 0, user, user);

    assertGt(out0, 0, "token0 returned even with minAmount1=0");
    assertGt(out1, 0, "token1 still returned in-range regardless of minAmount1=0");
  }

  /* ─────────────────── slisBNBx: setSlisBNBxMinter ───────────────── */

  address constant SLISBNBX = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
  address constant SLISBNBX_ADMIN = 0x702115D6d3Bbb37F407aae4dEcf9d09980e28ebc;

  function _deployMinter() internal returns (SlisBNBxMinter minter) {
    address[] memory modules = new address[](1);
    modules[0] = address(provider);

    SlisBNBxMinter.ModuleConfig[] memory configs = new SlisBNBxMinter.ModuleConfig[](1);
    configs[0] = SlisBNBxMinter.ModuleConfig({
      discount: 2e4, // 2 %
      feeRate: 3e4, // 3 %
      moduleAddress: address(provider)
    });

    SlisBNBxMinter impl = new SlisBNBxMinter(SLISBNBX);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(SlisBNBxMinter.initialize.selector, admin, manager, modules, configs)
    );
    minter = SlisBNBxMinter(address(proxy));

    // Give minter an MPC wallet with a large cap so minting never hits the cap.
    address mpc = makeAddr("mpc");
    vm.prank(manager);
    minter.addMPCWallet(mpc, 1_000_000_000 ether);

    // Authorise the minter contract to mint slisBNBx.
    vm.prank(SLISBNBX_ADMIN);
    ISlisBNBx(SLISBNBX).addMinter(address(minter));
  }

  function test_setSlisBNBxMinter_manager_succeeds() public {
    SlisBNBxMinter minter = _deployMinter();

    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    assertEq(provider.slisBNBxMinter(), address(minter));
  }

  function test_setSlisBNBxMinter_zeroAddress_disablesMinter() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.startPrank(manager);
    provider.setSlisBNBxMinter(address(minter));
    assertEq(provider.slisBNBxMinter(), address(minter));
    provider.setSlisBNBxMinter(address(0));
    assertEq(provider.slisBNBxMinter(), address(0));
    vm.stopPrank();
  }

  function test_setSlisBNBxMinter_notManager_reverts() public {
    SlisBNBxMinter minter = _deployMinter();

    vm.prank(user);
    vm.expectRevert();
    provider.setSlisBNBxMinter(address(minter));
  }

  /* ─────────────────── slisBNBx: deposit tracking ────────────────── */

  function test_deposit_updatesUserMarketDeposit() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares, "userMarketDeposit should match shares");
    assertEq(provider.userTotalDeposit(user), shares, "userTotalDeposit should match shares");
  }

  function test_deposit_twoDeposits_accumulatesTotal() public {
    (uint256 shares1, , ) = _deposit(user, 1_000 ether, 3 ether);
    (uint256 shares2, , ) = _deposit(user, 1_000 ether, 3 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares1 + shares2, "market deposit should accumulate");
    assertEq(provider.userTotalDeposit(user), shares1 + shares2, "total deposit should accumulate");
  }

  function test_deposit_twoUsers_trackingIsIndependent() public {
    (uint256 shares1, , ) = _deposit(user, 1_000 ether, 3 ether);
    (uint256 shares2, , ) = _deposit(user2, 2_000 ether, 6 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares1);
    assertEq(provider.userTotalDeposit(user), shares1);
    assertEq(provider.userMarketDeposit(user2, marketId), shares2);
    assertEq(provider.userTotalDeposit(user2), shares2);
  }

  /* ─────────────────── slisBNBx: withdraw tracking ───────────────── */

  function test_withdraw_updatesUserMarketDeposit() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    vm.prank(user);
    provider.withdraw(marketParams, shares, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    assertEq(provider.userMarketDeposit(user, marketId), 0, "market deposit should be 0 after full withdraw");
    assertEq(provider.userTotalDeposit(user), 0, "total deposit should be 0 after full withdraw");
  }

  function test_withdraw_partial_updatesTracking() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    uint256 half = shares / 2;

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(half);
    vm.prank(user);
    provider.withdraw(marketParams, half, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    uint256 remaining = provider.userMarketDeposit(user, marketId);
    assertApproxEqAbs(remaining, shares - half, 1, "market deposit should halve");
    assertEq(provider.userTotalDeposit(user), remaining, "total deposit matches market deposit");
  }

  /* ─────────────────── slisBNBx: liquidate tracking ──────────────── */

  function test_liquidate_syncsBorrowerToZero() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    assertEq(provider.userMarketDeposit(user, marketId), shares);

    // Simulate post-liquidation: Moolah reports 0 collateral for the borrower.
    vm.mockCall(
      MOOLAH_PROXY,
      abi.encodeWithSelector(IMoolah.position.selector, marketId, user),
      abi.encode(0, uint128(0), uint128(0))
    );

    vm.prank(MOOLAH_PROXY);
    provider.liquidate(marketId, user);

    assertEq(provider.userMarketDeposit(user, marketId), 0, "market deposit should clear after liquidation");
    assertEq(provider.userTotalDeposit(user), 0, "total deposit should clear after liquidation");
  }

  /* ─────────────────── slisBNBx: getUserBalanceInBnb ─────────────── */

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  uint256 constant BNB_PRICE = 700e8;

  function _mockAllPrices() internal {
    _mockOraclePrices(); // mocks USDC and WBNB prices
    vm.mockCall(RESILIENT_ORACLE, abi.encodeWithSelector(IOracle.peek.selector, BNB_ADDRESS), abi.encode(BNB_PRICE));
  }

  function test_getUserBalanceInBnb_zeroBeforeDeposit() public view {
    assertEq(provider.getUserBalanceInBnb(user), 0);
  }

  function test_getUserBalanceInBnb_nonzeroAfterDeposit() public {
    _mockAllPrices();
    _deposit(user, 1_000 ether, 3 ether);

    uint256 bnbValue = provider.getUserBalanceInBnb(user);
    assertGt(bnbValue, 0, "should return positive BNB value after deposit");
  }

  function test_getUserBalanceInBnb_proportionalToShares() public {
    _mockAllPrices();
    _deposit(user, 1_000 ether, 3 ether);
    _deposit(user2, 2_000 ether, 6 ether);

    uint256 value1 = provider.getUserBalanceInBnb(user);
    uint256 value2 = provider.getUserBalanceInBnb(user2);

    // user2 deposited ~2x; allow 2% tolerance for compounding and rounding.
    assertApproxEqRel(value2, value1 * 2, 0.02e18, "user2 BNB value should be ~2x user");
  }

  function test_getUserBalanceInBnb_matchesShareValueInBnb() public {
    _mockAllPrices();
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    // peek() returns (totalValue * 1e18 / supply) where totalValue is 8-dec USD.
    // getUserBalanceInBnb returns (shares * 1e18 * totalValue / supply / bnbPrice)
    //                           = shares * sharePrice / bnbPrice
    uint256 sharePrice = provider.peek(address(provider)); // 8-dec USD * 1e18 / liquidity-unit
    uint256 expectedBnbValue = (shares * sharePrice) / BNB_PRICE;

    uint256 actualBnbValue = provider.getUserBalanceInBnb(user);
    // Allow 1% for rounding between slot0-based amounts and oracle math.
    assertApproxEqRel(actualBnbValue, expectedBnbValue, 0.01e18, "BNB value should match share oracle price");
  }

  /* ─────────────────── slisBNBx: manual sync ─────────────────────── */

  function test_syncUserBalance_noOpWhenAlreadySynced() public {
    _deposit(user, 1_000 ether, 3 ether);

    uint256 depositBefore = provider.userMarketDeposit(user, marketId);
    provider.syncUserBalance(marketId, user);
    assertEq(provider.userMarketDeposit(user, marketId), depositBefore, "no change when already synced");
  }

  function test_bulkSyncUserBalance_syncsMultipleUsers() public {
    _deposit(user, 1_000 ether, 3 ether);
    _deposit(user2, 2_000 ether, 6 ether);

    uint256 d1 = provider.userMarketDeposit(user, marketId);
    uint256 d2 = provider.userMarketDeposit(user2, marketId);

    Id[] memory ids = new Id[](2);
    ids[0] = marketId;
    ids[1] = marketId;
    address[] memory accounts = new address[](2);
    accounts[0] = user;
    accounts[1] = user2;

    provider.bulkSyncUserBalance(ids, accounts);

    assertEq(provider.userMarketDeposit(user, marketId), d1, "user1 unchanged");
    assertEq(provider.userMarketDeposit(user2, marketId), d2, "user2 unchanged");
  }

  function test_bulkSyncUserBalance_lengthMismatch_reverts() public {
    Id[] memory ids = new Id[](2);
    ids[0] = marketId;
    ids[1] = marketId;
    address[] memory accounts = new address[](1);
    accounts[0] = user;

    vm.expectRevert("length mismatch");
    provider.bulkSyncUserBalance(ids, accounts);
  }

  // ── H-1 regression: foreign market ID must be rejected ────────────

  /// @dev Returns the Id of a live Moolah market whose collateralToken != address(provider).
  function _foreignMarketId() internal pure returns (Id) {
    // Use the first market in the live Moolah deployment (slisBNB / lisUSD).
    // Its collateralToken is slisBNB, not this V3Provider.
    MarketParams memory foreign = MarketParams({
      loanToken: LISUSD,
      collateralToken: 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B, // slisBNB
      oracle: RESILIENT_ORACLE,
      irm: 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6,
      lltv: 90 * 1e16
    });
    return foreign.id();
  }

  function test_syncUserBalance_foreignMarket_reverts() public {
    _deposit(user, 1_000 ether, 3 ether);
    uint256 totalBefore = provider.userTotalDeposit(user);

    vm.expectRevert("invalid market");
    provider.syncUserBalance(_foreignMarketId(), user);

    // Deposit tracking must be unchanged.
    assertEq(provider.userTotalDeposit(user), totalBefore);
  }

  function test_bulkSyncUserBalance_foreignMarket_reverts() public {
    _deposit(user, 1_000 ether, 3 ether);
    uint256 totalBefore = provider.userTotalDeposit(user);

    Id[] memory ids = new Id[](1);
    ids[0] = _foreignMarketId();
    address[] memory accounts = new address[](1);
    accounts[0] = user;

    vm.expectRevert("invalid market");
    provider.bulkSyncUserBalance(ids, accounts);

    assertEq(provider.userTotalDeposit(user), totalBefore);
  }

  /* ─────────────────── slisBNBx: minter integration ──────────────── */

  function test_withMinter_deposit_mintsSlisBNBx() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    _mockAllPrices();
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);

    // Deposit tracking
    assertEq(provider.userMarketDeposit(user, marketId), shares, "userMarketDeposit should equal shares");
    assertEq(provider.userTotalDeposit(user), shares, "userTotalDeposit should equal shares");
    // slisBNBx minted to user
    assertGt(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "slisBNBx should be minted to user after deposit");
  }

  function test_withMinter_withdraw_burnsSlisBNBx() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    _mockAllPrices();
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    assertGt(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "setup: slisBNBx minted after deposit");

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
    vm.prank(user);
    provider.withdraw(marketParams, shares, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    // Deposit tracking zeroed
    assertEq(provider.userMarketDeposit(user, marketId), 0, "userMarketDeposit should be 0 after full withdraw");
    assertEq(provider.userTotalDeposit(user), 0, "userTotalDeposit should be 0 after full withdraw");
    // slisBNBx burned
    assertEq(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "slisBNBx should be burned after full withdraw");
  }

  function test_withMinter_partialWithdraw_reducesSlisBNBx() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    _mockAllPrices();
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    uint256 slisBNBxAfterDeposit = ISlisBNBx(SLISBNBX).balanceOf(user);
    assertGt(slisBNBxAfterDeposit, 0);

    uint256 half = shares / 2;
    (uint256 exp0, uint256 exp1) = provider.previewRedeem(half);
    vm.prank(user);
    provider.withdraw(marketParams, half, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    uint256 remainingDeposit = provider.userMarketDeposit(user, marketId);
    // Deposit tracking reduced by half
    assertApproxEqAbs(remainingDeposit, shares - half, 1, "userMarketDeposit should halve");
    assertEq(provider.userTotalDeposit(user), remainingDeposit, "userTotalDeposit matches userMarketDeposit");
    // slisBNBx partially burned
    uint256 slisBNBxAfterWithdraw = ISlisBNBx(SLISBNBX).balanceOf(user);
    assertLt(slisBNBxAfterWithdraw, slisBNBxAfterDeposit, "slisBNBx should decrease after partial withdraw");
    assertGt(slisBNBxAfterWithdraw, 0, "some slisBNBx should remain after partial withdraw");
  }

  function test_withMinter_liquidate_burnsSlisBNBx() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    _mockAllPrices();
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    assertEq(provider.userMarketDeposit(user, marketId), shares, "setup: deposit tracked");
    assertGt(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "setup: slisBNBx minted after deposit");

    // Simulate full liquidation: Moolah reports 0 collateral for the borrower.
    vm.mockCall(
      MOOLAH_PROXY,
      abi.encodeWithSelector(IMoolah.position.selector, marketId, user),
      abi.encode(0, uint128(0), uint128(0))
    );

    vm.prank(MOOLAH_PROXY);
    provider.liquidate(marketId, user);

    // Deposit tracking zeroed
    assertEq(provider.userMarketDeposit(user, marketId), 0, "userMarketDeposit cleared after liquidation");
    assertEq(provider.userTotalDeposit(user), 0, "userTotalDeposit cleared after liquidation");
    // slisBNBx burned
    assertEq(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "slisBNBx burned after liquidation sync");
  }

  /* ─────────────────── borrow / repay / liquidate ─────────────────── */

  function _borrow(address _user, uint256 assets) internal {
    vm.prank(_user);
    moolah.borrow(marketParams, assets, 0, _user, _user);
  }

  function _debtOf(address _user) internal view returns (uint128 borrowShares) {
    (, borrowShares, ) = moolah.position(marketId, _user);
  }

  /// @dev Borrow 60% of the user's current collateral value. Safe to borrow (< LLTV)
  ///      but large enough that mocking the price to zero makes the position unhealthy.
  function _borrowAgainstCollateral(address _user) internal returns (uint256 borrowed) {
    (, , uint128 col) = moolah.position(marketId, _user);
    uint256 sharePrice = provider.peek(address(provider)); // 8-dec USD per share
    uint256 loanPrice = provider.peek(LISUSD); // 8-dec USD per lisUSD (~1e8)
    // 60% of collateral value in lisUSD units
    borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100);
    _borrow(_user, borrowed);
  }

  /// @dev Set collateral oracle price to zero, making any position with debt unhealthy.
  function _makeUnhealthy() internal {
    vm.mockCall(
      address(provider),
      abi.encodeWithSelector(IOracle.peek.selector, address(provider)),
      abi.encode(uint256(0))
    );
  }

  function test_borrow_afterDeposit_receivesLisUSD() public {
    _deposit(user, 1_000 ether, 3 ether);
    uint256 balBefore = IERC20(LISUSD).balanceOf(user);
    _borrow(user, 100 ether);
    assertEq(IERC20(LISUSD).balanceOf(user), balBefore + 100 ether);
    assertGt(_debtOf(user), 0, "borrow shares recorded");
  }

  function test_borrow_twoUsers_independentDebt() public {
    _deposit(user, 1_000 ether, 3 ether);
    _deposit(user2, 2_000 ether, 6 ether);
    _borrow(user, 100 ether);
    _borrow(user2, 200 ether);
    assertGt(_debtOf(user), 0);
    assertGt(_debtOf(user2), _debtOf(user), "user2 has more debt");
    assertEq(IERC20(LISUSD).balanceOf(user), 100 ether);
    assertEq(IERC20(LISUSD).balanceOf(user2), 200 ether);
  }

  function test_repay_full_clearsDebt() public {
    _deposit(user, 1_000 ether, 3 ether);
    _borrow(user, 100 ether);
    assertGt(_debtOf(user), 0);

    deal(LISUSD, user, 200 ether); // extra buffer for accrued interest
    vm.startPrank(user);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.repay(marketParams, 0, _debtOf(user), user, ""); // repay by shares → exact
    vm.stopPrank();

    assertEq(_debtOf(user), 0, "debt cleared after full repay");
  }

  function test_repay_partial_reducesDebt() public {
    _deposit(user, 1_000 ether, 3 ether);
    _borrow(user, 100 ether);
    uint128 sharesBefore = _debtOf(user);

    deal(LISUSD, user, 50 ether);
    vm.startPrank(user);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.repay(marketParams, 50 ether, 0, user, "");
    vm.stopPrank();

    uint128 sharesAfter = _debtOf(user);
    assertLt(sharesAfter, sharesBefore, "debt decreased");
    assertGt(sharesAfter, 0, "some debt remains");
  }

  function test_liquidate_seizedSharesSentToLiquidator() public {
    address liquidator = makeAddr("liquidator");
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    deal(LISUSD, liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.liquidate(marketParams, user, shares, 0, "");
    vm.stopPrank();

    assertGt(provider.balanceOf(liquidator), 0, "liquidator received shares");
    (, , uint128 colAfter) = moolah.position(marketId, user);
    assertEq(colAfter, 0, "borrower collateral seized");
    assertEq(provider.userMarketDeposit(user, marketId), 0, "deposit tracking cleared");
    assertEq(provider.userTotalDeposit(user), 0, "total deposit cleared");
  }

  function test_liquidate_liquidatorRedeemsSharesToTokens() public {
    address liquidator = makeAddr("liquidator");
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    deal(LISUSD, liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.liquidate(marketParams, user, shares, 0, "");

    uint256 seizedShares = provider.balanceOf(liquidator);
    (uint256 exp0, uint256 exp1) = provider.previewRedeem(seizedShares);
    (uint256 out0, uint256 out1) = provider.redeemShares(
      seizedShares,
      (exp0 * 99) / 100,
      (exp1 * 99) / 100,
      liquidator
    );
    vm.stopPrank();

    assertEq(provider.balanceOf(liquidator), 0, "shares burned after redeem");
    assertGt(out0 + out1, 0, "liquidator received tokens");
    assertEq(IERC20(USDC).balanceOf(liquidator), out0);
    assertEq(liquidator.balance, out1); // WBNB unwrapped to BNB
  }

  /* ───── peek() discontinuity when rebalance happens while TWAP lags ───── */

  /// @notice Demonstrates that rebalancing while spot has diverged far from TWAP
  ///         causes a peek() discontinuity — the oracle-reported share price jumps
  ///         even though no real value was created or destroyed.
  ///
  ///         Scenario:
  ///         1. User deposits into an in-range position.
  ///         2. A large swap pushes spot price far below tickLower (position → 100% USDC).
  ///         3. TWAP still reflects the old price (lagging behind spot).
  ///         4. peek() is called before and after rebalance — the share price jumps because
  ///            the TWAP tick lands in a completely different region of the new range vs the old range.
  ///
  ///         Before rebalance:
  ///           old range [tickLower, tickUpper], TWAP tick < old tickLower
  ///           → _getTotalAmountsAt(twap) = 100% token0
  ///           → peek = total0 × price0 / supply
  ///
  ///         After rebalance (new range centered below TWAP):
  ///           new range is ABOVE the current spot tick but BELOW the TWAP tick
  ///           → _getTotalAmountsAt(twap) evaluates position as if price is above new tickUpper
  ///           → 100% token1 (WBNB) at TWAP-implied amounts — different composition and value
  ///
  ///         This is the TWAP-stale-window risk: the oracle's view of token0/token1 split
  ///         doesn't match reality, and rebalancing changes which "wrong view" is computed.
  function test_peek_discontinuity_on_rebalance_with_stale_twap() public {
    _mockOraclePrices();

    // 1. User deposits and borrows against collateral.
    _deposit(user, 10_000 ether, 30 ether);
    uint256 shares = _collateral(user);
    assertGt(shares, 0);

    // Record peek() at the healthy state.
    uint256 peekHealthy = provider.peek(address(provider));
    assertGt(peekHealthy, 0, "peek should be non-zero after deposit");

    // 2. Push spot price far below tickLower.
    //    TWAP (30-min average) barely moves — it still reflects the old price range.
    _pushPriceBelowRange();

    (, int24 spotTickAfterSwap, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 twapTickAfterSwap = provider.getTwapTick();

    // Confirm TWAP is still well above spot — the stale window.
    assertLt(spotTickAfterSwap, provider.tickLower(), "spot should be below old tickLower");
    assertGt(twapTickAfterSwap, spotTickAfterSwap + 200, "TWAP should lag significantly behind spot");

    // 3. peek() before rebalance — TWAP evaluates old range.
    uint256 peekBeforeRebalance = provider.peek(address(provider));

    // 4. Rebalance: create new range centered around the new spot tick.
    //    Choose a range that is entirely BELOW the TWAP tick so that
    //    _getTotalAmountsAt(twapSqrtPrice) sees the new range as "price above tickUpper"
    //    → interprets the position as 100% token1 (WBNB).
    //
    //    Before rebalance, TWAP was below old tickLower → 100% token0 (USDC).
    //    After rebalance, TWAP is above new tickUpper → 100% token1 (WBNB).
    //    Same liquidity, but peek() reports a completely different token composition.
    // Place new range ABOVE spot (so only token0/USDC is needed to mint,
    // matching the 100%-USDC holdings) but BELOW the TWAP tick (so peek()
    // evaluates the new position as "price above tickUpper" → 100% token1).
    int24 newLower = spotTickAfterSwap + 100;
    int24 newUpper = spotTickAfterSwap + 500;

    // Ensure new range is entirely below the TWAP tick.
    assertLt(newUpper, twapTickAfterSwap, "new tickUpper should be below TWAP tick");
    // Ensure new range is entirely above the spot tick.
    assertGt(newLower, spotTickAfterSwap, "new tickLower should be above spot tick");

    // Collect total amounts for slippage params.
    (uint256 t0, uint256 t1) = provider.getTotalAmounts();

    vm.prank(bot);
    provider.rebalance(newLower, newUpper, 0, 0, t0, t1);

    // 5. peek() after rebalance — TWAP evaluates NEW range.
    uint256 peekAfterRebalance = provider.peek(address(provider));

    // The share price SHOULD be approximately the same (no real value change),
    // but due to TWAP staleness it can jump significantly.
    uint256 priceDelta;
    if (peekAfterRebalance > peekBeforeRebalance) {
      priceDelta = peekAfterRebalance - peekBeforeRebalance;
    } else {
      priceDelta = peekBeforeRebalance - peekAfterRebalance;
    }
    uint256 pctChange = (priceDelta * 1e18) / peekBeforeRebalance;

    // Log for visibility.
    emit log_named_uint("peek before rebalance (8 dec)", peekBeforeRebalance);
    emit log_named_uint("peek after  rebalance (8 dec)", peekAfterRebalance);
    emit log_named_uint("change %  (18 dec = 100%)", pctChange);
    emit log_named_int("spot  tick after swap", spotTickAfterSwap);
    emit log_named_int("TWAP  tick after swap", twapTickAfterSwap);
    emit log_named_int("new tickLower", newLower);
    emit log_named_int("new tickUpper", newUpper);

    // Without maxTickDeviation guard, the rebalance succeeds and causes a large
    // peek() discontinuity. This proves the TWAP-stale-window risk is real.
    assertGt(pctChange, 0.01e18, "peek() should show a >1% discontinuity due to stale TWAP");
  }

  /// @notice With maxTickDeviation set, the same rebalance is blocked — preventing
  ///         the peek() discontinuity from ever occurring.
  function test_peek_discontinuity_blocked_by_maxTickDeviation() public {
    _mockOraclePrices();
    _deposit(user, 10_000 ether, 30 ether);

    // Set the guard — only allow rebalance when spot ≈ TWAP.
    vm.prank(manager);
    provider.setMaxTickDeviation(100);

    _pushPriceBelowRange();

    (, int24 spotTickAfterSwap, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 newLower = spotTickAfterSwap + 100;
    int24 newUpper = spotTickAfterSwap + 500;
    (uint256 t0, uint256 t1) = provider.getTotalAmounts();

    vm.prank(bot);
    vm.expectRevert("twap deviation too high");
    provider.rebalance(newLower, newUpper, 0, 0, t0, t1);
  }

  /* ───── rebalance TWAP deviation guard ───── */

  function test_rebalance_succeeds_when_twap_deviation_within_limit() public {
    _deposit(user, 10_000 ether, 30 ether);

    // Set a generous deviation limit — slot0 and TWAP should be close after deposit.
    vm.prank(manager);
    provider.setMaxTickDeviation(5000);

    (, int24 spotTick, , , , , ) = IUniswapV3Pool(POOL).slot0();
    int24 twapTick = provider.getTwapTick();
    int24 delta = twapTick > spotTick ? twapTick - spotTick : spotTick - twapTick;
    assertLt(uint24(delta), 5000, "deviation should be within limit");

    // Rebalance to a slightly shifted range — should succeed.
    int24 newLower = provider.tickLower() - 100;
    int24 newUpper = provider.tickUpper() - 100;
    (uint256 t0, uint256 t1) = provider.getTotalAmounts();

    vm.prank(bot);
    provider.rebalance(newLower, newUpper, 0, 0, t0, t1);

    assertEq(provider.tickLower(), newLower, "tickLower should be updated");
    assertEq(provider.tickUpper(), newUpper, "tickUpper should be updated");
  }
}

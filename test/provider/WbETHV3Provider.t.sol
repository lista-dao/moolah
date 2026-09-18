// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";

import { WbETHV3Provider } from "../../src/provider/v3/WbETHV3Provider.sol";
import { WbETHV3DexAdapter } from "../../src/provider/v3/WbETHV3DexAdapter.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IWbETH } from "../../src/provider/interfaces/IWbETH.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";

/// @dev Minimal resilient-oracle mock: 8-decimal USD prices, settable per token.
contract MockOracle is IOracle {
  mapping(address => uint256) public price;

  function setPrice(address token, uint256 value) external {
    price[token] = value;
  }

  function peek(address token) external view returns (uint256) {
    return price[token];
  }

  function getTokenConfig(address) external pure returns (TokenConfig memory c) {
    return c;
  }
}

/// @dev Executes a direct Uniswap V3 pool swap (to skew the pool spot) and pays the callback.
contract PoolSwapper {
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  function swapExactIn(address pool, bool zeroForOne, uint256 amountIn) external {
    uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    IListaV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool));
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    address pool = abi.decode(data, (address));
    if (amount0Delta > 0) IERC20(IListaV3Pool(pool).token0()).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(IListaV3Pool(pool).token1()).transfer(msg.sender, uint256(amount1Delta));
  }
}

/// @notice Ethereum fork tests for the wbETH/WETH V3 LP topology (WbETHV3DexAdapter + WbETHV3Provider
///         + generic V3ProviderOracle). The mechanism is identical to wstETH/WETH (shared base +
///         SwapInventoryLib), so the deposit / withdraw / redeem / swap-rebalance PATH is validated by
///         WstETHV3Provider.t.sol; these tests cover the wbETH-specific wiring that does NOT need a deep
///         pool — rate source (exchangeRate), pair guard, pure-rate valuation, oracle, and config.
///
/// @dev No deep wbETH/WETH AMM exists on Ethereum (the only Uniswap V3 pool, 0.3%, is empty), so
///      functional deposit/rebalance fork tests await a seeded Lista pool; the rebalance swap venue is
///      backend-built calldata against a whitelisted pair, validated end-to-end by WstETHV3Provider.t.sol.
contract WbETHV3ProviderTest is Test {
  using MarketParamsLib for MarketParams;

  /* the (empty) Uniswap V3 wbETH/WETH 0.3% pool — a first deposit seeds it with our own liquidity */
  address constant POOL = 0xFEBf58c2E1bBaBE298A9E5EC099385a4B641AE18;
  address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  uint24 constant FEE = 3000;

  address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1; // token0
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token1
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

  address constant MOOLAH_PROXY = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address constant MOOLAH_ADMIN = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // admin timelock (DEFAULT_ADMIN)
  address constant IRM = 0x8b7d334d243b74D63C4b963893267A0F5240F990;

  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MOOLAH_MANAGER = keccak256("MANAGER");

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant RANGE_LOWER_BPS = 50;
  uint256 constant RANGE_UPPER_BPS = 50;
  uint256 constant TWAP_DEV_BPS = 25;
  uint256 constant LLTV = 86 * 1e16;
  uint256 constant ETH_USD = 3000e8; // mock ETH price, 8 decimals

  Moolah moolah;
  WbETHV3DexAdapter adapter;
  WbETHV3Provider provider;
  V3ProviderOracle providerOracle;
  MockOracle oracle;
  PoolSwapper swapper;
  MarketParams marketParams;
  Id marketId;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"), 23566432);

    // Upgrade Moolah to the local implementation (keeps the split-topology wiring consistent with source).
    address newMoolahImpl = address(new Moolah());
    vm.prank(MOOLAH_ADMIN);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newMoolahImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Mock resilient oracle: WETH = ETH price; wbETH = ETH price × exchangeRate (rate-derived). USDT = $1.
    oracle = new MockOracle();
    uint256 rate = IWbETH(WBETH).exchangeRate();
    oracle.setPrice(WETH, ETH_USD);
    oracle.setPrice(WBETH, (ETH_USD * rate) / 1e18);
    oracle.setPrice(USDC, 1e8);
    oracle.setPrice(USDT, 1e8);

    WbETHV3DexAdapter adapterImpl = new WbETHV3DexAdapter(NPM, WBETH, WETH, FEE, TWAP_PERIOD);
    adapter = WbETHV3DexAdapter(
      payable(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeCall(WbETHV3DexAdapter.initialize, (admin, manager, RANGE_LOWER_BPS, RANGE_UPPER_BPS, TWAP_DEV_BPS))
        )
      )
    );

    WbETHV3Provider provImpl = new WbETHV3Provider(MOOLAH_PROXY, address(adapter));
    provider = WbETHV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            WbETHV3Provider.initialize,
            (admin, manager, bot, address(oracle), WETH, "wbETH/WETH vLP", "vLP-wbETH-WETH")
          )
        )
      )
    );

    vm.prank(admin);
    adapter.setProvider(address(provider));

    V3ProviderOracle oracleImpl = new V3ProviderOracle(address(adapter), address(provider), WBETH, WETH);
    providerOracle = V3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeCall(V3ProviderOracle.initialize, (admin, manager, address(oracle), uint256(0)))
        )
      )
    );

    swapper = new PoolSwapper();

    // Grant ourselves OPERATOR (createMarket) + MANAGER (setProvider) on the forked Moolah.
    vm.startPrank(MOOLAH_ADMIN);
    IAccessControl(MOOLAH_PROXY).grantRole(OPERATOR, address(this));
    IAccessControl(MOOLAH_PROXY).grantRole(MOOLAH_MANAGER, address(this));
    vm.stopPrank();

    marketParams = MarketParams({
      loanToken: USDT,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    marketId = marketParams.id();

    moolah.createMarket(marketParams);
    moolah.setProvider(marketId, address(provider), true);
  }

  /* ───────────────────────────── tests ────────────────────────────── */

  function test_initialize() public view {
    assertEq(adapter.TOKEN0(), WBETH);
    assertEq(adapter.TOKEN1(), WETH);
    assertEq(adapter.WRAPPED_NATIVE(), WETH);
    assertEq(adapter.FEE(), FEE);
    assertEq(adapter.POOL(), POOL);
    assertEq(adapter.maxTwapDeviationBps(), 25, "TWAP clamp band defaults below the upper range margin");
    assertEq(adapter.centerRateThresholdBps(), 1, "default threshold 1bp: minimal anti-churn floor");
    // rate wiring: the center rate is wbETH.exchangeRate(), not stEthPerToken or pool price.
    assertEq(adapter.lastCenterRate(), IWbETH(WBETH).exchangeRate(), "center rate from exchangeRate");
    assertEq(adapter.provider(), address(provider));
    assertEq(provider.asset(), WETH, "accounting asset");
    assertEq(providerOracle.TOKEN0(), WBETH);
    assertEq(providerOracle.TOKEN1(), WETH);
  }

  function test_constructor_revertsWrongPair() public {
    // USDC/WETH 0.3% pool exists and is correctly ordered, so the base ordering + pool-existence
    // checks pass; only the wbETH/WETH pair guard rejects it.
    vm.expectRevert(WbETHV3DexAdapter.NotWbEthWethPair.selector);
    new WbETHV3DexAdapter(NPM, USDC, WETH, FEE, TWAP_PERIOD);
  }

  /// @notice Pure-rate valuation (band = 0) reflects wbETH.exchangeRate() and needs no pool TWAP — so it
  ///         works even against the empty wbETH/WETH pool (the bootstrap mode for a fresh Lista pool).
  function test_fairSqrtPrice_pureRate_matchesExchangeRate() public {
    vm.prank(manager);
    adapter.setMaxTwapDeviationBps(0);

    uint160 sp = adapter.fairSqrtPriceX96();
    assertGt(sp, 0, "pure-rate fair price non-zero (no observe dependency)");

    // (sqrtP / 2^96)^2 ≈ WETH-per-wbETH ≈ exchangeRate.
    uint256 impliedRate = FullMath.mulDiv(uint256(sp) * uint256(sp), 1e18, 1 << 192);
    assertApproxEqRel(impliedRate, IWbETH(WBETH).exchangeRate(), 1e15, "fair price tracks exchangeRate");
  }

  /// @notice The oracle delegates any non-share token to the resilient oracle (wbETH priced rate-derived).
  function test_oracle_delegatesNonShareToken() public view {
    assertEq(providerOracle.peek(WBETH), (ETH_USD * IWbETH(WBETH).exchangeRate()) / 1e18, "wbETH price delegated");
    assertEq(providerOracle.peek(WETH), ETH_USD, "WETH price delegated");
  }

  /* ─────────────────────── access control / config ─────────────────────── */

  function test_setSwapPairWhitelist_onlyManager() public {
    vm.expectRevert();
    adapter.setSwapPairWhitelist(address(0xBEEF), true);

    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(0xBEEF), true);
    assertTrue(adapter.swapPairWhitelist(address(0xBEEF)));

    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(0xBEEF), false);
    assertFalse(adapter.swapPairWhitelist(address(0xBEEF)));
  }

  function test_setSwapPairWhitelist_zeroReverts() public {
    vm.prank(manager);
    vm.expectRevert(V3DexAdapter.ZeroAddress.selector);
    adapter.setSwapPairWhitelist(address(0), true);
  }

  function test_setMaxTwapDeviationBps_capEnforced() public {
    uint256 overCap = adapter.MAX_TWAP_DEVIATION_BPS() + 1;
    vm.prank(manager);
    vm.expectRevert(WbETHV3DexAdapter.InvalidDeviation.selector);
    adapter.setMaxTwapDeviationBps(overCap);

    vm.prank(manager);
    adapter.setMaxTwapDeviationBps(0);
    assertEq(adapter.maxTwapDeviationBps(), 0, "clamp band settable to 0 (pure rate)");
  }

  /* ─────────── deposit crediting: min(fair, spot) shares (deposit-withdraw cycle) ───────────

     WbETHV3Provider does not override V3Provider.deposit, so these exercise the SAME min(fair,spot)
     credit path proven for slisBNB/wstETH — here against the wbETH topology (exchangeRate-anchored fair).
     The only wbETH/WETH pool is empty, so the first deposit bootstraps it with our own liquidity; pure-rate
     mode + a wide center band let that seed land despite the pool's un-arbitraged slot0. */

  /// @dev Relax the guards the empty/un-arbitraged pool would otherwise trip, then seed the position with
  ///      our own liquidity. Fair stays exchangeRate-anchored; spot = the (manipulable) slot0.
  function _bootstrap() internal {
    vm.startPrank(manager);
    adapter.setMaxTwapDeviationBps(0); // pure-rate fair: no pool TWAP/observe dependency
    vm.stopPrank();
    _depositRet(50 ether, 50 ether);
  }

  /// @dev Deposit as `user`, returning the consumed amounts. Per-leg floors 0 so a skewed spot cannot
  ///      trip the slippage floor — we are measuring the share credit here.
  function _depositRet(uint256 amtWb, uint256 amtWeth) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(WBETH, user, amtWb);
    deal(WETH, user, amtWeth);
    vm.startPrank(user);
    IERC20(WBETH).approve(address(provider), amtWb);
    IERC20(WETH).approve(address(provider), amtWeth);
    (shares, used0, used1) = provider.deposit(marketParams, amtWb, amtWeth, 0, 0, 0, user);
    vm.stopPrank();
  }

  /// @dev 8-dec USD value of a (wbETH, WETH) amount pair through the mock resilient oracle.
  function _valueUSD(uint256 amtWb, uint256 amtWeth) internal view returns (uint256) {
    return (amtWb * oracle.peek(WBETH)) / 1e18 + (amtWeth * oracle.peek(WETH)) / 1e18;
  }

  /// @dev WETH->wbETH swap to push the pool spot up (instant; exchangeRate-anchored fair unmoved).
  function _swapPoolUp(uint256 amountIn) internal {
    deal(WETH, address(swapper), amountIn);
    swapper.swapExactIn(POOL, false, amountIn); // token1 (WETH) in → price up
  }

  /// @dev A spot pushed further from the rate-anchored fair credits fewer shares for the same deposit —
  ///      the spot quote wins the min, capping the credit at what a spot exit can back.
  function test_deposit_skewedSpotCreditsFewerShares() public {
    _bootstrap();
    _swapPoolUp(20 ether); // push spot clearly above fair

    uint256 snap = vm.snapshotState();
    (uint256 sharesNear, , ) = _depositRet(10 ether, 10 ether);
    vm.revertToState(snap);

    _swapPoolUp(20 ether); // push further from fair
    (uint256 sharesFar, , ) = _depositRet(10 ether, 10 ether);

    assertLt(sharesFar, sharesNear, "further skew, fewer shares");
    assertGt(sharesFar, 0, "mints > 0");
  }

  /// @dev previewDepositShares returns exactly what deposit() mints at a skewed spot.
  function test_previewDepositShares_matchesActualMint() public {
    _bootstrap();
    _swapPoolUp(20 ether);

    uint256 preview = provider.previewDepositShares(10 ether, 10 ether);
    (uint256 actual, , ) = _depositRet(10 ether, 10 ether);
    assertEq(preview, actual, "preview == mint (skewed)");
    assertGt(actual, 0, "mints > 0");
  }

  /// @dev The deposit->withdraw cycle at a skewed spot is not profitable on wbETH either: the exiter
  ///      cannot walk out with more fair (USD) value than it put in.
  function test_depositWithdraw_cycleNotProfitableAtSkewedSpot() public {
    _bootstrap();
    _swapPoolUp(20 ether); // skew slot0 before the cycle

    (uint256 shares, uint256 in0, uint256 in1) = _depositRet(10 ether, 10 ether);
    (uint256 e0, uint256 e1) = provider.previewRedeemUnderlying(shares);
    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(
      marketParams,
      shares,
      (e0 * 90) / 100,
      (e1 * 90) / 100,
      user,
      user
    );

    assertLe(_valueUSD(out0, out1), _valueUSD(in0, in1), "cycle extracts no value");
  }
}

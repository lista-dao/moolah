// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";

import { WbETHV3Provider } from "../../src/provider/v3/WbETHV3Provider.sol";
import { WbETHV3DexAdapter } from "../../src/provider/v3/WbETHV3DexAdapter.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IWbETH } from "../../src/provider/interfaces/IWbETH.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";

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
  /* the (empty) Uniswap V3 wbETH/WETH 0.3% pool — used only to satisfy the adapter's pool wiring */
  address constant POOL = 0xFEBf58c2E1bBaBE298A9E5EC099385a4B641AE18;
  address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  uint24 constant FEE = 3000;

  address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1; // token0
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token1
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  address constant MOOLAH_PROXY = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant ETH_USD = 3000e8; // mock ETH price, 8 decimals

  WbETHV3DexAdapter adapter;
  WbETHV3Provider provider;
  V3ProviderOracle providerOracle;
  MockOracle oracle;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"), 23566432);

    // Mock resilient oracle: WETH = ETH price; wbETH = ETH price × exchangeRate (rate-derived). USDC = $1.
    oracle = new MockOracle();
    uint256 rate = IWbETH(WBETH).exchangeRate();
    oracle.setPrice(WETH, ETH_USD);
    oracle.setPrice(WBETH, (ETH_USD * rate) / 1e18);
    oracle.setPrice(USDC, 1e8);

    WbETHV3DexAdapter adapterImpl = new WbETHV3DexAdapter(NPM, WBETH, WETH, FEE, TWAP_PERIOD);
    adapter = WbETHV3DexAdapter(
      payable(new ERC1967Proxy(address(adapterImpl), abi.encodeCall(WbETHV3DexAdapter.initialize, (admin, manager))))
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
  }

  /* ───────────────────────────── tests ────────────────────────────── */

  function test_initialize() public view {
    assertEq(adapter.TOKEN0(), WBETH);
    assertEq(adapter.TOKEN1(), WETH);
    assertEq(adapter.WRAPPED_NATIVE(), WETH);
    assertEq(adapter.FEE(), FEE);
    assertEq(adapter.POOL(), POOL);
    assertEq(adapter.maxTwapDeviationBps(), 100, "TWAP clamp band defaults to range width");
    assertEq(adapter.centerRateThresholdBps(), 100, "default threshold 1%");
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
}

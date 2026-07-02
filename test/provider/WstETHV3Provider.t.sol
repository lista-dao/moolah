// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { WstETHV3Provider } from "../../src/provider/v3/WstETHV3Provider.sol";
import { WstETHV3DexAdapter } from "../../src/provider/v3/WstETHV3DexAdapter.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IWstETH } from "../../src/provider/interfaces/IWstETH.sol";
import { SwapInventoryLib } from "../../src/provider/libraries/SwapInventoryLib.sol";
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

/// @dev Executes a direct Uniswap V3 pool swap (to manipulate the pool price) and pays the callback.
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

/// @dev Minimal DEX-agnostic swap target standing in for the venue the BOT backend would route to:
///      pulls `amountIn` of tokenIn from the caller (the adapter, which has forceApproved it) and
///      sends a fixed `amountOut` of tokenOut to `to`. Pre-fund it with tokenOut via `deal`.
contract MockSwap {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    IERC20(tokenOut).transfer(to, amountOut);
  }
}

/// @notice Ethereum fork tests for the wstETH/WETH V3 LP topology (WstETHV3DexAdapter + WstETHV3Provider
///         + generic V3ProviderOracle), against the live Uniswap V3 wstETH/WETH 0.01% pool. Verifies:
///         the rate-implied oracle is invariant to pool-price manipulation; the backend-built rebalance
///         swap recenters value-neutrally through a whitelisted venue; and (the linchpin) the swap is
///         bounded by the backend-supplied amountOutMin and only allowed against a whitelisted pair.
contract WstETHV3ProviderTest is Test {
  using MarketParamsLib for MarketParams;

  /* live Uniswap V3 wstETH/WETH 0.01% pool */
  address constant POOL = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
  address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  uint24 constant FEE = 100;

  address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // token0
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token1

  address constant MOOLAH_PROXY = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address constant MOOLAH_ADMIN = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // admin timelock (DEFAULT_ADMIN)
  address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant IRM = 0x8b7d334d243b74D63C4b963893267A0F5240F990;

  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MOOLAH_MANAGER = keccak256("MANAGER");

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant LLTV = 86 * 1e16;
  uint256 constant ETH_USD = 3000e8; // mock ETH price, 8 decimals

  Moolah moolah;
  WstETHV3DexAdapter adapter;
  WstETHV3Provider provider;
  V3ProviderOracle providerOracle;
  MockOracle oracle;
  PoolSwapper swapper;
  MockSwap mockSwap;
  MarketParams marketParams;
  Id marketId;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"), 23566432);

    // Upgrade Moolah to the local implementation (keeps the split-topology wiring consistent with the
    // current source regardless of the deployed impl at this block).
    address newMoolahImpl = address(new Moolah());
    vm.prank(MOOLAH_ADMIN);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newMoolahImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Mock resilient oracle: WETH = ETH price; wstETH = ETH price × stEthPerToken (rate-derived, like
    // the live ResilientOracle). USDT = $1.
    oracle = new MockOracle();
    uint256 rate = IWstETH(WSTETH).stEthPerToken();
    oracle.setPrice(WETH, ETH_USD);
    oracle.setPrice(WSTETH, (ETH_USD * rate) / 1e18);
    oracle.setPrice(USDT, 1e8);

    // 1) DEX adapter (NFT custodian + rate/rebalance logic).
    WstETHV3DexAdapter adapterImpl = new WstETHV3DexAdapter(NPM, WSTETH, WETH, FEE, TWAP_PERIOD);
    adapter = WstETHV3DexAdapter(
      payable(new ERC1967Proxy(address(adapterImpl), abi.encodeCall(WstETHV3DexAdapter.initialize, (admin, manager))))
    );

    // 2) Vault (ERC-4626 shares + Moolah wiring). accountingAsset = WETH.
    WstETHV3Provider provImpl = new WstETHV3Provider(MOOLAH_PROXY, address(adapter));
    provider = WstETHV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            WstETHV3Provider.initialize,
            (admin, manager, bot, address(oracle), WETH, "wstETH/WETH vLP", "vLP-wstETH-WETH")
          )
        )
      )
    );

    // 3) Wire adapter -> vault (one-time, admin).
    vm.prank(admin);
    adapter.setProvider(address(provider));

    // 4) Oracle (Moolah market.oracle; prices the share off the adapter's rate-implied fair view).
    V3ProviderOracle oracleImpl = new V3ProviderOracle(address(adapter), address(provider), WSTETH, WETH);
    providerOracle = V3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeCall(V3ProviderOracle.initialize, (admin, manager, address(oracle), uint256(0)))
        )
      )
    );

    swapper = new PoolSwapper();

    // DEX-agnostic swap stand-in: whitelist it so the backend-built rebalance swapData may target it.
    mockSwap = new MockSwap();
    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(mockSwap), true);

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

  /* ───────────────────────────── helpers ──────────────────────────── */

  function _deposit(uint256 amtWst, uint256 amtWeth) internal returns (uint256 shares) {
    deal(WSTETH, user, amtWst);
    deal(WETH, user, amtWeth);
    (, uint256 e0, uint256 e1) = provider.previewDepositAmounts(amtWst, amtWeth);
    vm.startPrank(user);
    IERC20(WSTETH).approve(address(provider), amtWst);
    IERC20(WETH).approve(address(provider), amtWeth);
    (shares, , ) = provider.deposit(marketParams, amtWst, amtWeth, (e0 * 99) / 100, (e1 * 99) / 100, user);
    vm.stopPrank();
  }

  /// @dev Encode the backend rebalance blob the adapter decodes: (swapPair, sellToken0, amountIn,
  ///      amountOutMin, nativeIn, innerSwapData). nativeIn=false here (DEX venues; no native-in on ETH).
  ///      Empty blob ⇒ recenter without converting inventory.
  function _swapData(
    address swapPair,
    bool sellToken0,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes memory inner
  ) internal pure returns (bytes memory) {
    return abi.encode(swapPair, sellToken0, amountIn, amountOutMin, false, inner);
  }

  /// @dev Inner calldata the adapter low-level-calls on the whitelisted MockSwap: pull `amountIn` of
  ///      tokenIn from the adapter, send `amountOut` of tokenOut back to it.
  function _mockInner(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut
  ) internal view returns (bytes memory) {
    return abi.encodeCall(MockSwap.swap, (tokenIn, tokenOut, amountIn, amountOut, address(adapter)));
  }

  /// @dev WETH->wstETH swap to push the pool price up (wstETH expensive in-pool). INSTANT — no time
  ///      passes, so the TWAP is (almost) unmoved and only slot0 shifts.
  function _swapPoolUp(uint256 amountIn) internal {
    deal(WETH, address(swapper), amountIn);
    swapper.swapExactIn(POOL, false, amountIn); // token1 (WETH) in → price up
  }

  /// @dev Sustained manipulation: swap, then warp past the TWAP window so the TWAP reflects it.
  function _manipulatePoolUp(uint256 amountIn) internal {
    _swapPoolUp(amountIn);
    vm.warp(block.timestamp + 3600);
  }

  /* ───────────────────────────── tests ────────────────────────────── */

  function test_initialize() public view {
    assertEq(adapter.TOKEN0(), WSTETH);
    assertEq(adapter.TOKEN1(), WETH);
    assertEq(adapter.WRAPPED_NATIVE(), WETH);
    assertEq(adapter.FEE(), FEE);
    assertEq(adapter.POOL(), POOL);
    assertTrue(adapter.swapPairWhitelist(address(mockSwap)), "swap venue whitelisted in setUp");
    assertEq(adapter.maxTwapDeviationBps(), 100, "TWAP clamp band defaults to range width");
    assertEq(adapter.lastCenterRate(), IWstETH(WSTETH).stEthPerToken(), "center rate from stEthPerToken");
    assertEq(adapter.centerRateThresholdBps(), 100, "default threshold 1%");
    assertEq(adapter.provider(), address(provider));
    assertEq(provider.asset(), WETH, "accounting asset");
    assertEq(provider.WRAPPED_NATIVE(), WETH);
    assertEq(providerOracle.TOKEN0(), WSTETH);
    assertEq(providerOracle.TOKEN1(), WETH);
  }

  function test_deposit_firstDeposit() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    assertGt(shares, 0, "shares minted");
    (, , uint128 collateral) = moolah.position(marketId, user);
    assertEq(collateral, shares, "collateral == shares supplied");
    assertGt(adapter.tokenId(), 0, "position minted");
  }

  function test_deposit_secondDeposit_sharesProportional() public {
    _deposit(10 ether, 10 ether);
    uint256 supplyBefore = provider.totalSupply();
    uint256 peekBefore = providerOracle.peek(address(provider));

    uint256 shares2 = _deposit(10 ether, 10 ether);
    // second equal deposit roughly doubles supply; per-share price stays ~constant
    assertApproxEqRel(provider.totalSupply(), supplyBefore + shares2, 1e16);
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "share price ~stable");
  }

  function test_withdraw() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    uint256 wstBefore = IERC20(WSTETH).balanceOf(user);
    uint256 wethBefore = IERC20(WETH).balanceOf(user);

    vm.prank(user);
    (uint256 a0, uint256 a1) = provider.withdraw(marketParams, shares, 0, 0, user, user);

    assertGt(a0 + a1, 0, "received underlying");
    assertEq(IERC20(WSTETH).balanceOf(user), wstBefore + a0);
    // WETH leg is unwrapped to native ETH by the adapter; user gets ETH, WETH balance unchanged.
    assertEq(IERC20(WETH).balanceOf(user), wethBefore, "WETH leg paid as native ETH");
    (, , uint128 collateral) = moolah.position(marketId, user);
    assertEq(collateral, 0, "collateral fully withdrawn");
  }

  function test_redeemShares_byHolder() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    // move shares out of Moolah to the user so they hold them directly
    vm.prank(user);
    provider.withdrawShares(marketParams, shares, user, user);
    assertEq(provider.balanceOf(user), shares);

    vm.prank(user);
    (uint256 a0, uint256 a1) = provider.redeemShares(shares, 0, 0, user);
    assertGt(a0 + a1, 0, "redeemed underlying");
    assertEq(provider.balanceOf(user), 0);
  }

  /* ─────── LP oracle: TWAP clamped to rate — slot0-resistant + clamp-bounded ─────── */

  /// @notice Priced off TWAP (not slot0): an INSTANT swap (no elapsed time) barely moves the TWAP, so
  ///         peek is unchanged even though the slot0/spot composition shifts hard.
  function test_peek_resistsInstantManipulation() public {
    _deposit(10 ether, 10 ether);

    uint256 peekBefore = providerOracle.peek(address(provider));
    (uint256 s0Before, ) = provider.getTotalAmounts(); // spot/slot0-based, for contrast

    _swapPoolUp(2000 ether); // instant, no warp

    (uint256 s0After, ) = provider.getTotalAmounts();
    assertTrue(s0After != s0Before, "spot composition shifts with slot0");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 1e16, "peek resists instant manipulation");
    assertGt(peekBefore, 0, "peek non-zero");
  }

  /// @notice The rate clamp bounds the valuation: with the band set to 0 the price is pinned to the
  ///         rate, so even a SUSTAINED (TWAP-moving) manipulation cannot move peek.
  function test_peek_clampPinsToRateWhenBandZero() public {
    _deposit(10 ether, 10 ether);
    vm.prank(manager);
    adapter.setMaxTwapDeviationBps(0);

    uint256 peekBefore = providerOracle.peek(address(provider));
    _manipulatePoolUp(2000 ether); // sustained: TWAP moves, but clamp=0 pins valuation to the rate
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 5e15, "clamp=0 pins valuation to rate");
  }

  /// @notice totalAssets (same valuation price) likewise resists instant manipulation.
  function test_totalAssets_resistsInstantManipulation() public {
    _deposit(10 ether, 10 ether);
    uint256 taBefore = provider.totalAssets();
    _swapPoolUp(2000 ether); // instant
    assertApproxEqRel(provider.totalAssets(), taBefore, 1e16, "totalAssets resists instant manipulation");
  }

  /// @notice Pure-rate mode (band = 0) skips the TWAP entirely — NO pool observe()/cardinality
  ///         dependency. peek works even when the pool cannot serve observations (e.g. a freshly
  ///         built Lista pool before cardinality is seeded), whereas the default band needs observe().
  function test_peek_pureRate_noObserveDependency() public {
    _deposit(10 ether, 10 ether);

    // Simulate a pool with no TWAP history: every observe() call reverts.
    vm.mockCallRevert(POOL, abi.encodeWithSignature("observe(uint32[])"), bytes("no observations"));

    // Default band (>0) reads the TWAP → peek reverts when observe() is unavailable.
    vm.expectRevert();
    providerOracle.peek(address(provider));

    // Pure-rate mode (band = 0) must not touch observe() → peek still works.
    vm.prank(manager);
    adapter.setMaxTwapDeviationBps(0);
    assertGt(providerOracle.peek(address(provider)), 0, "pure-rate peek works without pool TWAP observations");
  }

  /* ───────────────────── swap-based rebalance ───────────────────── */

  /// @notice Empty swapData ⇒ recenter only (no inventory conversion). Value-neutral.
  function test_rebalance_recentersValueNeutral() public {
    _deposit(10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, block.timestamp, "");

    assertGt(adapter.tokenId(), oldTokenId, "position re-minted");
    assertLt(adapter.tickLower(), adapter.tickUpper(), "valid range");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "rebalance ~value-neutral");
    assertEq(adapter.lastCenterRate(), IWstETH(WSTETH).stEthPerToken(), "center rate updated");
  }

  /// @notice Backend-built swapData routes the conversion through a whitelisted venue. A fair-rate swap
  ///         (wstETH→WETH at the LST rate) is value-neutral and the position is re-minted.
  function test_rebalance_swapExecutesThroughWhitelistedVenue() public {
    _deposit(10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Sell 0.5 wstETH for WETH at the fair LST rate; fund the venue with the WETH it must pay out.
    uint256 rate = IWstETH(WSTETH).stEthPerToken();
    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    deal(WETH, address(mockSwap), fairOut);

    bytes memory inner = _mockInner(WSTETH, WETH, amountIn, fairOut);
    bytes memory data = _swapData(address(mockSwap), true, amountIn, (fairOut * 99) / 100, inner);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, block.timestamp, data);

    assertGt(adapter.tokenId(), oldTokenId, "position re-minted after swap");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "fair swap ~value-neutral");
  }

  /// @notice Linchpin: the backend-supplied `amountOutMin` is enforced on the measured output. A venue
  ///         that under-delivers (returns less than amountOutMin) reverts the whole rebalance.
  function test_rebalance_revertsBelowAmountOutMin() public {
    _deposit(10 ether, 10 ether);

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256 rate = IWstETH(WSTETH).stEthPerToken();
    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    deal(WETH, address(mockSwap), fairOut);

    // Venue pays only half of fairOut, but the backend demanded the full fairOut as amountOutMin.
    bytes memory inner = _mockInner(WSTETH, WETH, amountIn, fairOut / 2);
    bytes memory data = _swapData(address(mockSwap), true, amountIn, fairOut, inner);

    vm.prank(bot);
    vm.expectRevert(SwapInventoryLib.InsufficientOutput.selector);
    provider.rebalance(0, 0, 0, block.timestamp, data);
  }

  /// @notice The adapter only allows whitelisted swap venues; a non-whitelisted target reverts before
  ///         any call is made.
  function test_rebalance_revertsNotWhitelistedPair() public {
    _deposit(10 ether, 10 ether);

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    MockSwap rogue = new MockSwap(); // never whitelisted
    bytes memory inner = _mockInner(WSTETH, WETH, 0.5 ether, 0.5 ether);
    bytes memory data = _swapData(address(rogue), true, 0.5 ether, 0, inner);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.NotWhitelistedPair.selector);
    provider.rebalance(0, 0, 0, block.timestamp, data);
  }

  /* ─────────────────────── access control / config ─────────────────────── */

  function test_rebalance_onlyBot() public {
    _deposit(10 ether, 10 ether);
    vm.expectRevert();
    provider.rebalance(0, 0, 0, block.timestamp, "");
  }

  function test_rebalance_revertsAfterDeadline() public {
    _deposit(10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);
    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.DeadlineExpired.selector);
    provider.rebalance(0, 0, 0, block.timestamp - 1, "");
  }

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

  /// @notice Defense-in-depth: a swap venue must never be the position's own tokens / pool / NPM, else
  ///         crafted swapData could move the adapter's inventory. Whitelisting them reverts.
  function test_setSwapPairWhitelist_rejectsSensitiveAddresses() public {
    address npm = address(adapter.POSITION_MANAGER());
    vm.startPrank(manager);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(WSTETH, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(WETH, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(POOL, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(npm, true);
    vm.stopPrank();
  }

  function test_setMaxTwapDeviationBps_capEnforced() public {
    uint256 overCap = adapter.MAX_TWAP_DEVIATION_BPS() + 1;
    vm.prank(manager);
    vm.expectRevert(WstETHV3DexAdapter.InvalidDeviation.selector);
    adapter.setMaxTwapDeviationBps(overCap);

    vm.prank(manager);
    adapter.setMaxTwapDeviationBps(0);
    assertEq(adapter.maxTwapDeviationBps(), 0, "clamp band settable to 0 (pure rate)");
  }

  function test_constructor_revertsWrongPair() public {
    // USDC/USDT 0.01% pool exists and is correctly ordered, so the base ordering + pool-existence
    // checks pass; only the wstETH/WETH pair guard rejects it.
    vm.expectRevert(WstETHV3DexAdapter.NotWstEthWethPair.selector);
    new WstETHV3DexAdapter(NPM, USDC, USDT, FEE, TWAP_PERIOD);
  }

  /* ─────────────────── wiring cross-validation (M4) ─────────────────── */

  /// @dev A second, independent adapter for the same pair — `provider` is wired to `adapter`, not this.
  function _freshAdapter() internal returns (WstETHV3DexAdapter) {
    WstETHV3DexAdapter impl2 = new WstETHV3DexAdapter(NPM, WSTETH, WETH, FEE, TWAP_PERIOD);
    return
      WstETHV3DexAdapter(
        payable(new ERC1967Proxy(address(impl2), abi.encodeCall(WstETHV3DexAdapter.initialize, (admin, manager))))
      );
  }

  /// @notice setProvider rejects a vault that doesn't point back to this adapter (mis-wire guard).
  function test_setProvider_revertsOnAdapterMismatch() public {
    WstETHV3DexAdapter adapter2 = _freshAdapter();
    vm.prank(admin);
    vm.expectRevert(V3DexAdapter.ProviderAdapterMismatch.selector);
    adapter2.setProvider(address(provider)); // provider.ADAPTER() == adapter, not adapter2
  }

  /// @notice The oracle constructor rejects a share whose adapter isn't the one the oracle reads.
  function test_oracleConstructor_revertsOnShareAdapterMismatch() public {
    WstETHV3DexAdapter adapter2 = _freshAdapter(); // same pair ⇒ token check passes, share check fails
    vm.expectRevert(V3ProviderOracle.ShareAdapterMismatch.selector);
    new V3ProviderOracle(address(adapter2), address(provider), WSTETH, WETH);
  }
}

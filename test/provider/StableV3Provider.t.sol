// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { StableV3Provider } from "../../src/provider/v3/StableV3Provider.sol";
import { StableV3DexAdapter } from "../../src/provider/v3/StableV3DexAdapter.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { V3Provider } from "../../src/provider/v3/V3Provider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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

/// @dev Whitelisted "swap venue" that re-enters Moolah.liquidate while the adapter is mid-rebalance.
contract ReenteringVenue {
  Moolah immutable MOOLAH;
  address immutable BORROWER;
  address immutable SHARE;
  address immutable ORACLE;
  MarketParams mp;
  bool public attempted;
  bool public liquidated;
  bytes public err;
  uint256 public peekDuring;

  constructor(Moolah _moolah, MarketParams memory _mp, address _borrower, address _oracle, address _loanToken) {
    MOOLAH = _moolah;
    mp = _mp;
    BORROWER = _borrower;
    SHARE = _mp.collateralToken;
    ORACLE = _oracle;
    IERC20(_loanToken).approve(address(_moolah), type(uint256).max);
  }

  fallback() external payable {
    attempted = true;
    peekDuring = IOracle(ORACLE).peek(SHARE);
    (, , uint128 collateral) = MOOLAH.position(MarketParamsLib.id(mp), BORROWER);
    try MOOLAH.liquidate(mp, BORROWER, collateral, 0, "") {
      liquidated = true;
    } catch (bytes memory e) {
      err = e;
    }
  }
}

/// @dev Pins the oracle-ratio rate substitution. Mounted on the live slisBNB/WBNB pool with a mock oracle:
///      the rate SOURCE is what is under test, not the tokens.
contract StableV3ProviderTest is Test {
  using MarketParamsLib for MarketParams;

  address constant POOL = 0xe1B404Aaf60eEc5c8A1FEDE7dcDC0EAb9C69662F;
  address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
  uint24 constant FEE = 100;

  address constant TOKEN0 = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // pool token0
  address constant TOKEN1 = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // pool token1 (wrapped native)

  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  uint256 constant LLTV = 70 * 1e16;

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant RANGE_LOWER_BPS = 10;
  uint256 constant RANGE_UPPER_BPS = 10;
  uint256 constant SPOT_DEV_BPS = 10; // sized with the range, not the LST default

  /// @dev token0 a hair under $1 — a stable pair's normal resting state.
  uint256 constant PRICE0 = 99_990_000; // $0.9999, 8-dec
  uint256 constant PRICE1 = 100_000_000; // $1.0000, 8-dec

  Moolah moolah;
  StableV3DexAdapter adapter;
  StableV3Provider provider;
  V3ProviderOracle providerOracle;
  MockOracle oracle;
  MarketParams marketParams;
  Id marketId;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    address newImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    oracle = new MockOracle();
    oracle.setPrice(TOKEN0, PRICE0);
    oracle.setPrice(TOKEN1, PRICE1);

    StableV3DexAdapter adapterImpl = new StableV3DexAdapter(
      NPM,
      TOKEN0,
      TOKEN1,
      FEE,
      TWAP_PERIOD,
      TOKEN1,
      address(oracle)
    );
    adapter = StableV3DexAdapter(
      payable(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeCall(
            StableV3DexAdapter.initialize,
            (admin, manager, RANGE_LOWER_BPS, RANGE_UPPER_BPS, SPOT_DEV_BPS)
          )
        )
      )
    );

    StableV3Provider provImpl = new StableV3Provider(MOOLAH_PROXY, address(adapter));
    provider = StableV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            StableV3Provider.initialize,
            (admin, manager, bot, address(oracle), TOKEN1, "Stable V3 LP", "sv3LP")
          )
        )
      )
    );

    vm.prank(admin);
    adapter.setProvider(address(provider));

    V3ProviderOracle oImpl = new V3ProviderOracle(address(adapter), address(provider), TOKEN0, TOKEN1);
    providerOracle = V3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oImpl),
          abi.encodeCall(V3ProviderOracle.initialize, (admin, manager, address(oracle), 0))
        )
      )
    );

    oracle.setPrice(LISUSD, 1e8);
    marketParams = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    marketId = marketParams.id();
    vm.prank(OPERATOR);
    moolah.createMarket(marketParams);
    vm.prank(MANAGER_ADDR);
    moolah.setProvider(marketId, address(provider), true);
  }

  /* ─────────────────── the oracle ratio IS the rate ─────────────────── */

  function test_fairPrice_tracksOracleRatio() public view {
    assertEq(adapter.centerRate(), (PRICE0 * 1e18) / PRICE1, "rate = oracle price ratio");
    assertGt(adapter.fairSqrtPriceX96(), 0, "fair derives from it");
  }

  function test_fairPrice_movesWithTheOracle() public {
    uint160 before = adapter.fairSqrtPriceX96();
    oracle.setPrice(TOKEN0, (PRICE0 * 101) / 100); // token0 richens 1%
    assertGt(adapter.fairSqrtPriceX96(), before, "fair follows the feed");
  }

  /// @dev At rate == 0 the base falls back to TWAP and every rate-anchored guard no-ops.
  function test_rateIsNonZero_soRateAnchoredGuardsStayLive() public view {
    assertGt(adapter.centerRate(), 0, "guards key off a non-zero rate");
    assertGt(adapter.lastCenterRate(), 0, "recentre anchor recorded at init");
  }

  /// @dev A dropped feed must not peg fair at an arbitrary ratio.
  function test_fairPrice_revertsOnZeroFeed() public {
    oracle.setPrice(TOKEN0, 0);
    vm.expectRevert(StableV3DexAdapter.OracleZero.selector);
    adapter.fairSqrtPriceX96();

    oracle.setPrice(TOKEN0, PRICE0);
    oracle.setPrice(TOKEN1, 0);
    vm.expectRevert(StableV3DexAdapter.OracleZero.selector);
    adapter.fairSqrtPriceX96();
  }

  /* ───────────────────────── range centring ───────────────────────── */

  function test_openingRange_bracketsTheOracleImpliedPrice() public view {
    int24 lower = adapter.tickLower();
    int24 upper = adapter.tickUpper();
    assertLt(lower, upper, "range is valid");

    int24 fairTick = _tickOf(adapter.fairSqrtPriceX96());
    assertLt(lower, fairTick, "fair sits strictly inside");
    assertLt(fairTick, upper, "fair sits strictly inside");
  }

  function test_openingRange_honoursTheTightStableMargins() public view {
    assertEq(adapter.rangeLowerBps(), RANGE_LOWER_BPS);
    assertEq(adapter.rangeUpperBps(), RANGE_UPPER_BPS);
    // +/-10bps ~ 20 ticks before spacing alignment.
    assertLt(adapter.tickUpper() - adapter.tickLower(), 40, "range is stable-tight, not LST-wide");
  }

  /// @dev The base seeds the LST default (50); a stable pair must be able to size the gate with its range.
  function test_openingSpotGate_honoursTheInitParam() public view {
    assertEq(adapter.maxSpotDeviationBps(), SPOT_DEV_BPS, "spot gate taken from initialize, not the LST default");
  }

  /* ───────────────────────────── wiring ───────────────────────────── */

  function test_vaultAndAdapterShareTheSameOracle() public view {
    assertEq(provider.resilientOracle(), adapter.RESILIENT_ORACLE(), "one feed for range and share price");
  }

  function test_setProvider_rejectsMismatchedOracle() public {
    MockOracle other = new MockOracle();
    other.setPrice(TOKEN0, PRICE0);
    other.setPrice(TOKEN1, PRICE1);

    StableV3DexAdapter impl = new StableV3DexAdapter(NPM, TOKEN0, TOKEN1, FEE, TWAP_PERIOD, TOKEN1, address(other));
    StableV3DexAdapter a2 = StableV3DexAdapter(
      payable(
        new ERC1967Proxy(
          address(impl),
          abi.encodeCall(
            StableV3DexAdapter.initialize,
            (admin, manager, RANGE_LOWER_BPS, RANGE_UPPER_BPS, SPOT_DEV_BPS)
          )
        )
      )
    );

    // Vault wired to `oracle`, adapter to `other`.
    StableV3Provider pImpl = new StableV3Provider(MOOLAH_PROXY, address(a2));
    StableV3Provider p2 = StableV3Provider(
      payable(
        new ERC1967Proxy(
          address(pImpl),
          abi.encodeCall(
            StableV3Provider.initialize,
            (admin, manager, bot, address(oracle), TOKEN1, "Mismatched", "mm")
          )
        )
      )
    );

    vm.prank(admin);
    vm.expectRevert(StableV3DexAdapter.OracleMismatch.selector);
    a2.setProvider(address(p2));
  }

  /* ─────────────────────────── lifecycle ─────────────────────────── */

  /// @dev Only the rate source changes; the base flow must work unchanged.
  function test_lifecycle_depositThenRedeem() public {
    (uint256 shares, , ) = _depositRaw(10 ether, 10 ether);
    assertGt(shares, 0, "deposit mints");
    assertEq(_collateral(user), shares, "shares land as Moolah collateral");

    vm.prank(user);
    provider.withdrawShares(marketParams, shares, user, user);
    assertEq(provider.balanceOf(user), shares, "pulled to the wallet");

    // Wrapped-native leg returns unwrapped.
    uint256 before = IERC20(TOKEN0).balanceOf(user) + IERC20(TOKEN1).balanceOf(user) + user.balance;
    vm.prank(user);
    provider.redeemShares(shares, 0, 0, user);
    assertEq(provider.balanceOf(user), 0, "shares burned");
    assertGt(
      IERC20(TOKEN0).balanceOf(user) + IERC20(TOKEN1).balanceOf(user) + user.balance,
      before,
      "underlying returned"
    );
  }

  function test_lifecycle_compoundDeploysIdle() public {
    _depositRaw(10 ether, 10 ether); // first deposit opens the position
    _depositRaw(5 ether, 5 ether); // subsequent deposits park as idle
    assertGt(adapter.idleToken0() + adapter.idleToken1(), 0, "subsequent deposit parks as idle");

    vm.prank(manager);
    adapter.setMaxSpotDeviationBps(10_000); // fixture pool sits far from the mock oracle ratio
    vm.prank(bot);
    provider.compound(0, 0);
    assertGt(uint256(uint160(adapter.tokenId())), 0, "position exists after compound");
  }

  /// @dev Rate-implied pairs never read the observation ring: no cardinality precondition at launch.
  function test_fairPrice_needsNoPoolObservations() public {
    _depositRaw(10 ether, 10 ether); // peek is 0 on an empty vault
    vm.mockCallRevert(POOL, abi.encodeWithSignature("observe(uint32[])"), bytes("OLD"));
    assertGt(adapter.fairSqrtPriceX96(), 0, "fair survives a dead observation ring");
    assertGt(providerOracle.peek(address(provider)), 0, "so does the share price");
  }

  /* ───────────────────────── rebalance noOp ───────────────────────── */

  /// @dev noOp with an unchanged range: compound in place, no burn / re-mint.
  function test_rebalance_noOp_compoundsInPlace() public {
    _depositRaw(10 ether, 10 ether); // opens the position
    _depositRaw(1 ether, 1 ether); // parks idle
    assertGt(adapter.idleToken1(), 0, "idle parked");
    uint256 tokenBefore = adapter.tokenId();
    uint128 liqBefore = adapter.totalLiquidity();
    vm.startPrank(manager);
    adapter.setCenterRateThresholdBps(0); // rate did not move: lift the anti-churn floor for the test
    adapter.setMaxSpotDeviationBps(0); // this fixture's mock fair sits far from the live pool spot
    vm.stopPrank();
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, "", true);
    assertEq(adapter.tokenId(), tokenBefore, "no re-mint");
    assertGt(adapter.totalLiquidity(), liqBefore, "idle compounded into the existing position");
    // spot is above the range here, so only the token1 leg is addable; token0 idle stays parked
    assertEq(adapter.idleToken1(), 0, "addable idle deployed");
  }

  /* ───────────────────────── range margin bounds ───────────────────────── */

  /// @dev setRangeBps enforces the initializer's bounds (0 < bps < BPS); a zero margin would collapse
  ///      the range, which _initialTickRange now rejects instead of relocating to the top tick.
  function test_setRangeBps_mirrorsInitBounds() public {
    vm.startPrank(manager);
    vm.expectRevert(V3DexAdapter.InvalidParam.selector);
    adapter.setRangeBps(0, 10);
    vm.expectRevert(V3DexAdapter.InvalidParam.selector);
    adapter.setRangeBps(10, 0);
    vm.expectRevert(V3DexAdapter.InvalidParam.selector);
    adapter.setRangeBps(10_000, 10);
    vm.expectRevert(V3DexAdapter.InvalidParam.selector);
    adapter.setRangeBps(10, 10_000);
    vm.expectEmit(true, true, true, true);
    emit V3DexAdapter.RangeBpsChanged(20, 30);
    adapter.setRangeBps(20, 30);
    vm.stopPrank();
    assertEq(adapter.rangeLowerBps(), 20);
    assertEq(adapter.rangeUpperBps(), 30);
  }

  /* ───────────────────────── zero share price ───────────────────────── */

  /// @dev A position that values to 0 prices at 0: no new borrowing, but a seize-by-amount liquidation
  ///      still clears the borrower and socializes the bad debt (nothing reverts, nothing is overvalued).
  function test_zeroSharePrice_blocksBorrowButLiquidationStillClears() public {
    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");
    _depositRaw(300 ether, 300 ether);
    vm.prank(user);
    moolah.borrow(marketParams, 100 ether, 0, user, user);
    uint256 collateral = _collateral(user);
    (uint128 supplyBefore, , , , , ) = moolah.market(marketId);

    // The position collapses to a zero-value composition (dust / wiped backing).
    vm.mockCall(
      address(adapter),
      abi.encodeWithSelector(bytes4(keccak256("positionAmountsAt(uint160)"))),
      abi.encode(uint256(0), uint256(0))
    );
    assertEq(providerOracle.peek(address(provider)), 0, "prices at 0, no revert");

    vm.prank(user);
    vm.expectRevert(bytes("insufficient collateral"));
    moolah.borrow(marketParams, 1 ether, 0, user, user);

    (uint256 seized, uint256 repaid) = moolah.liquidate(marketParams, user, collateral, 0, "");
    assertEq(seized, collateral, "all collateral seized");
    assertEq(repaid, 0, "nothing repaid at price 0");
    (, uint128 debt, uint128 left) = moolah.position(marketId, user);
    assertEq(debt, 0, "debt written off");
    assertEq(left, 0);
    (uint128 supplyAfter, , , , , ) = moolah.market(marketId);
    assertLt(supplyAfter, supplyBefore, "bad debt socialized to suppliers");
  }

  /* ───────────────────────── oracle construction order ───────────────────────── */

  /// @dev Built against a share proxy that has not been initialized, the oracle would snapshot 0 share
  ///      decimals forever; the constructor rejects it.
  function test_oracleConstructor_rejectsUninitializedShare() public {
    StableV3Provider impl = new StableV3Provider(MOOLAH_PROXY, address(adapter));
    address uninit = address(new ERC1967Proxy(address(impl), ""));
    assertEq(IERC20Metadata(uninit).decimals(), 0, "uninitialized share reports 0 decimals");
    vm.expectRevert(V3ProviderOracle.ShareNotInitialized.selector);
    new V3ProviderOracle(address(adapter), uninit, TOKEN0, TOKEN1);
  }

  /* ───────────────────────── provider registration ───────────────────────── */

  /// @dev A market that uses our share as collateral but was never registered with Moolah.setProvider
  ///      lets collateral leave without our hooks; deposit and supplyShares refuse it, exits still work.
  function test_entries_requireMoolahProviderRegistration() public {
    oracle.setPrice(USDT, 1e8);
    MarketParams memory unregistered = MarketParams({
      loanToken: USDT,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    vm.prank(OPERATOR);
    moolah.createMarket(unregistered);
    assertEq(moolah.providers(unregistered.id(), address(provider)), address(0), "not registered");

    deal(TOKEN0, user, 10 ether);
    deal(TOKEN1, user, 10 ether);
    vm.startPrank(user);
    IERC20(TOKEN0).approve(address(provider), 10 ether);
    IERC20(TOKEN1).approve(address(provider), 10 ether);
    vm.expectRevert(V3Provider.ProviderNotRegistered.selector);
    provider.deposit(unregistered, 10 ether, 10 ether, 0, 0, 0, user);
    vm.stopPrank();

    // Shares obtained in the registered market cannot be supplied into the unregistered one either,
    // but they can still be redeemed.
    (uint256 sh, , ) = _depositRaw(10 ether, 10 ether);
    vm.startPrank(user);
    provider.withdrawShares(marketParams, sh, user, user);
    vm.expectRevert(V3Provider.ProviderNotRegistered.selector);
    provider.supplyShares(unregistered, sh, user);
    provider.redeemShares(sh, 0, 0, user);
    vm.stopPrank();
    assertEq(provider.balanceOf(user), 0, "exit path untouched");
  }

  /* ───────────────────────── opening range rounding ───────────────────────── */

  /// @dev Both edges round OUTWARD: the aligned lower tick sits at or below the lower target price and
  ///      the aligned upper tick at or above the upper one (fixture: rate 0.9999, 10/10 bps, spacing 1).
  function test_openingRange_bothEdgesRoundOutward() public view {
    uint256 rate = adapter.centerRate();
    uint160 sqrtLower = _sqrtFromRate((rate * (10_000 - RANGE_LOWER_BPS)) / 10_000);
    uint160 sqrtUpper = _sqrtFromRate((rate * (10_000 + RANGE_UPPER_BPS)) / 10_000);
    assertLe(TickMath.getSqrtRatioAtTick(adapter.tickLower()), sqrtLower, "lower edge at or below target");
    assertGe(TickMath.getSqrtRatioAtTick(adapter.tickUpper()), sqrtUpper, "upper edge at or above target");
    assertEq(adapter.tickLower(), -12);
    assertEq(adapter.tickUpper(), 9); // was 8: the floored price-to-tick ate the upper margin
  }

  /// @dev An upper target exactly on a tick: the floored sqrt lands one wei under it, so without the
  ///      outward step the upper edge collapses onto the centre (rate 1.0, 1/1 bps → [-2, 0]).
  function test_openingRange_exactTickTargetKeepsUpperMargin() public {
    MockOracle par = new MockOracle();
    par.setPrice(TOKEN0, 1e8);
    par.setPrice(TOKEN1, 1e8);
    StableV3DexAdapter a = _deployAdapter(address(par), 1, 1, SPOT_DEV_BPS);
    assertEq(a.tickLower(), -2);
    assertEq(a.tickUpper(), 1, "upper margin survives the exact-tick target");
  }

  /* ───────────────────────── liquidation during rebalance ───────────────────────── */

  /// @dev Mid-rebalance (NFT burned, idle cleared) the share prices at 0. A whitelisted venue
  ///      that re-enters Moolah.liquidate in that window must be stopped by the provider's guard.
  function test_liquidate_duringRebalance_isBlockedByReentrancyGuard() public {
    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");

    _depositRaw(300 ether, 300 ether); // opens single-sided here (spot is out of range): ~$300 of collateral
    vm.prank(user);
    moolah.borrow(marketParams, 100 ether, 0, user, user);
    uint256 collateralBefore = _collateral(user);

    ReenteringVenue venue = new ReenteringVenue(moolah, marketParams, user, address(providerOracle), LISUSD);
    deal(LISUSD, address(venue), 1 ether);
    vm.startPrank(manager);
    adapter.setSwapPairWhitelist(address(venue), true);
    adapter.setCenterRateThresholdBps(0);
    vm.stopPrank();

    // Full path (non-empty swapData): sell 1 WBNB to the venue, which moves nothing and re-enters.
    bytes memory swapData = abi.encode(address(venue), false, uint256(1 ether), uint256(0), false, bytes(""));
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, swapData, false);

    assertTrue(venue.attempted(), "venue was called mid-rebalance");
    assertEq(venue.peekDuring(), 0, "the window prices the share at 0");
    assertFalse(venue.liquidated(), "liquidation did not go through");
    assertEq(bytes4(venue.err()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    assertEq(_collateral(user), collateralBefore, "collateral untouched");
  }

  function _deployAdapter(
    address _oracle,
    uint256 lowerBps,
    uint256 upperBps,
    uint256 spotDevBps
  ) internal returns (StableV3DexAdapter a) {
    StableV3DexAdapter impl = new StableV3DexAdapter(NPM, TOKEN0, TOKEN1, FEE, TWAP_PERIOD, TOKEN1, _oracle);
    a = StableV3DexAdapter(
      payable(
        new ERC1967Proxy(
          address(impl),
          abi.encodeCall(StableV3DexAdapter.initialize, (admin, manager, lowerBps, upperBps, spotDevBps))
        )
      )
    );
  }

  /// @dev Mirrors the adapter's rate → sqrtPriceX96 conversion (both fixture tokens are 18-dec).
  function _sqrtFromRate(uint256 rate) internal pure returns (uint160) {
    return uint160(Math.sqrt(FullMath.mulDiv(rate, 1 << 192, 1e18)));
  }

  /* ───────────────────────── compound cooldown ───────────────────────── */

  /// @dev Liquidity-adding compounds are spaced by cooldownBlocks; a cooldown expiry re-opens.
  function test_compound_cooldown_blocksBackToBackCompounds() public {
    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    vm.prank(manager);
    adapter.setMaxSpotDeviationBps(0); // this fixture's mock fair sits far from the live pool spot
    vm.prank(bot);
    provider.compound(0, 0);
    assertEq(adapter.lastCompoundBlock(), block.number, "cooldown armed by a liquidity-adding compound");

    _depositRaw(1 ether, 1 ether); // fresh idle to compound
    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.CompoundCooldown.selector));
    provider.compound(0, 0);

    vm.roll(block.number + adapter.cooldownBlocks());
    vm.prank(bot);
    provider.compound(0, 0);
    assertEq(adapter.idleToken1(), 0, "compound re-opens once the cooldown has elapsed");
  }

  /// @dev A compound the spot gate skips adds no liquidity and must not arm the cooldown.
  function test_compound_cooldown_notArmedWhenGateSkips() public {
    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    vm.prank(bot);
    provider.compound(0, 0); // fixture spot is outside the 10 bps gate → skipped, idle stays
    assertGt(adapter.idleToken1(), 0, "skipped");
    assertEq(adapter.lastCompoundBlock(), 0, "not armed");

    vm.prank(manager);
    adapter.setMaxSpotDeviationBps(0);
    vm.prank(bot);
    provider.compound(0, 0); // same block: allowed, the previous attempt did not count
    assertEq(adapter.idleToken1(), 0, "deployed");
  }

  /// @dev The rebalance no-op path compounds too, so it shares the same cooldown.
  function test_rebalance_noOp_underCompoundCooldown_reverts() public {
    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    vm.startPrank(manager);
    adapter.setMaxSpotDeviationBps(0);
    adapter.setCenterRateThresholdBps(0);
    vm.stopPrank();
    vm.prank(bot);
    provider.compound(0, 0);

    _depositRaw(1 ether, 1 ether);
    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.CompoundCooldown.selector));
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, "", true);

    vm.roll(block.number + adapter.cooldownBlocks());
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, "", true);
    assertEq(adapter.idleToken1(), 0, "no-op rebalance compounds once the cooldown has elapsed");
  }

  function test_setCooldownBlocks_managerOnly_zeroDisables() public {
    assertEq(adapter.cooldownBlocks(), 300, "init default");
    vm.prank(user);
    vm.expectRevert();
    adapter.setCooldownBlocks(1);

    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    vm.startPrank(manager);
    adapter.setMaxSpotDeviationBps(0);
    vm.expectEmit(true, true, true, true);
    emit V3DexAdapter.CooldownBlocksChanged(0);
    adapter.setCooldownBlocks(0);
    vm.stopPrank();
    vm.prank(bot);
    provider.compound(0, 0);
    assertEq(adapter.lastCompoundBlock(), block.number, "armed");
    _depositRaw(1 ether, 1 ether); // fresh idle
    vm.prank(bot);
    provider.compound(0, 0); // same block: allowed, cooldown disabled
    assertEq(adapter.idleToken1(), 0, "second compound in the same block deployed the idle");
  }

  /// @dev noOp forwards minAmount0/1 as the compound's floors. The implicit short-circuit needs them to be
  ///      0, so the same call without noOp would burn and re-mint instead.
  function test_rebalance_noOp_forwardsMinAmountsAsCompoundFloors() public {
    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    uint256 tokenBefore = adapter.tokenId();
    uint128 liqBefore = adapter.totalLiquidity();
    vm.startPrank(manager);
    adapter.setMaxSpotDeviationBps(0);
    adapter.setCenterRateThresholdBps(0);
    vm.stopPrank();
    vm.startPrank(bot);
    vm.expectRevert(); // NPM slippage check: the floor is forwarded and cannot be met
    provider.rebalance(0, type(uint256).max, 0, 0, 0, block.timestamp, "", true);
    provider.rebalance(0, 1, 0, 0, 0, block.timestamp, "", true); // spot above range: token1 leg deploys
    vm.stopPrank();
    assertEq(adapter.tokenId(), tokenBefore, "compounded in place, no re-mint");
    assertGt(adapter.totalLiquidity(), liqBefore, "idle compounded");
    assertEq(adapter.idleToken1(), 0, "addable idle deployed");
  }

  /// @dev noOp when the fair price moved: the recomputed range differs → revert, never the full path.
  function test_rebalance_noOp_revertsWhenRangeMoved() public {
    _depositRaw(10 ether, 10 ether);
    _depositRaw(1 ether, 1 ether);
    uint256 tokenBefore = adapter.tokenId();
    oracle.setPrice(TOKEN0, (PRICE0 * 10_005) / 10_000); // +5 bps: passes anti-churn, shifts the range
    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.RangeMoved.selector));
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, "", true);
    assertEq(adapter.tokenId(), tokenBefore, "position untouched");
    assertGt(adapter.idleToken1(), 0, "idle untouched");
  }

  /// @dev noOp contradicts any conversion / target / liquidity parameter.
  function test_rebalance_noOp_rejectsConflictingParams() public {
    _depositRaw(10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);
    vm.startPrank(bot);
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.InvalidParam.selector));
    provider.rebalance(0, 0, 1, 0, 0, block.timestamp, "", true);
    uint160 fair = adapter.fairSqrtPriceX96(); // hoisted: expectRevert binds to the NEXT external call
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.InvalidParam.selector));
    provider.rebalance(0, 0, 0, fair, 0, block.timestamp, "", true);
    vm.expectRevert(abi.encodeWithSelector(V3DexAdapter.InvalidParam.selector));
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, hex"01", true);
    vm.stopPrank();
  }

  /// @dev The same all-zero call WITHOUT noOp still takes the full path once the range moved (documented
  ///      residual: no target, no minLiquidity — the BOT must not use it as a compound substitute).
  function test_rebalance_allZeroWithoutNoOp_reMintsWhenRangeMoved() public {
    _depositRaw(10 ether, 10 ether);
    uint256 tokenBefore = adapter.tokenId();
    oracle.setPrice(TOKEN0, (PRICE0 * 10_005) / 10_000);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, 0, block.timestamp, "", false);
    assertTrue(adapter.tokenId() != tokenBefore, "full path re-minted the position");
  }

  function _depositRaw(uint256 a0, uint256 a1) internal returns (uint256, uint256, uint256) {
    deal(TOKEN0, user, a0);
    deal(TOKEN1, user, a1);
    vm.startPrank(user);
    IERC20(TOKEN0).approve(address(provider), a0);
    IERC20(TOKEN1).approve(address(provider), a1);
    (uint256 sh, uint256 u0, uint256 u1) = provider.deposit(marketParams, a0, a1, 0, 0, 0, user);
    vm.stopPrank();
    return (sh, u0, u1);
  }

  function _collateral(address who) internal view returns (uint256 c) {
    (, , c) = moolah.position(marketId, who);
  }

  /// @dev Largest tick with sqrt ratio <= the price, mirroring the adapter.
  function _tickOf(uint160 sqrtPriceX96) internal pure returns (int24) {
    int24 low = TickMath.MIN_TICK;
    int24 high = TickMath.MAX_TICK;
    while (low < high) {
      int24 mid = int24((int256(low) + int256(high) + 1) / 2);
      if (TickMath.getSqrtRatioAtTick(mid) <= sqrtPriceX96) low = mid;
      else high = mid - 1;
    }
    return low;
  }
}

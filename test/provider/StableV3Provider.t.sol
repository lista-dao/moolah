// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { StableV3Provider } from "../../src/provider/v3/StableV3Provider.sol";
import { StableV3DexAdapter } from "../../src/provider/v3/StableV3DexAdapter.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";

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

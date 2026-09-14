// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SlisBNBV3Provider } from "../../src/provider/v3/SlisBNBV3Provider.sol";
import { SlisBNBV3DexAdapter } from "../../src/provider/v3/SlisBNBV3DexAdapter.sol";
import { SlisBNBV3ProviderOracle } from "../../src/provider/v3/SlisBNBV3ProviderOracle.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";
import { V3Provider } from "../../src/provider/v3/V3Provider.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { V3ProviderLens } from "../../src/provider/v3/V3ProviderLens.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IV3PoolMinimal } from "../../src/provider/interfaces/IV3PoolMinimal.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TokenConfig, IOracle } from "moolah/interfaces/IOracle.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal resilient-oracle mock (copy of the SlisBNBV3Provider fixture's): 8-decimal USD prices.
contract LeakMockOracle is IOracle {
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

/// @dev Faithful StakeManager stand-in at a FIXED rate (copy of the fixture's MockStakeManager).
contract LeakMockStakeManager {
  uint256 public immutable rate;
  address public immutable slisBnb;

  constructor(uint256 _rate, address _slisBnb) {
    rate = _rate;
    slisBnb = _slisBnb;
  }

  function convertSnBnbToBnb(uint256 amount) external view returns (uint256) {
    return (amount * rate) / 1e18;
  }

  function convertBnbToSnBnb(uint256 amount) external view returns (uint256) {
    return (amount * 1e18) / rate;
  }

  function deposit() external payable {
    IERC20(slisBnb).transfer(msg.sender, (msg.value * 1e18) / rate);
  }

  function instantWithdraw(uint256 amount) external returns (uint256 bnbAmount) {
    IERC20(slisBnb).transferFrom(msg.sender, address(this), amount);
    bnbAmount = (amount * rate) / 1e18;
    (bool ok, ) = msg.sender.call{ value: bnbAmount }("");
    require(ok, "bnb send failed");
  }

  receive() external payable {}
}

/// @dev Pool swapper that stops the pool exactly at a caller-supplied sqrt price limit, so the test can
///      park the spot at a precise deviation from fair. Funded generously; only spends what is needed.
contract LimitSwapper {
  function swapToLimit(address pool, bool zeroForOne, uint256 amountInMax, uint160 sqrtLimit) external {
    IListaV3Pool(pool).swap(address(this), zeroForOne, int256(amountInMax), sqrtLimit, abi.encode(pool));
  }

  function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
    _pay(a0, a1, data);
  }

  function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
    _pay(a0, a1, data);
  }

  function _pay(int256 a0, int256 a1, bytes calldata data) internal {
    address pool = abi.decode(data, (address));
    if (a0 > 0) IERC20(IListaV3Pool(pool).token0()).transfer(msg.sender, uint256(a0));
    if (a1 > 0) IERC20(IListaV3Pool(pool).token1()).transfer(msg.sender, uint256(a1));
  }
}

/// @dev Whitelistable swap venue stand-in that pays an arbitrary (under-)amount — used to find where the
///      existing loss caps actually bite when a compromised BOT combines targetSqrtPriceX96 == 0 with a
///      value-destroying inventory-conversion swap. Copy of the fixture's MockSwap.
contract LeakMockSwap {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    IERC20(tokenOut).transfer(to, amountOut);
  }
}

/// @notice MEASUREMENT-ONLY suite (no src/ change, no fix): quantifies
///           M4 — the fair-NAV leak of a BOT rebalance() that passes targetSqrtPriceX96 == 0 (which
///                opts out of the spot-deviation gate at V3DexAdapter.sol:553-560), and how much of it
///                the existing maxRebalanceLossBp / maxDailyLossUsd caps actually stop;
///           M5 — the idle fee-dilution term alpha*F, where alpha = idle / (deployed + idle).
///         setUp is copied from test/provider/SlisBNBV3Provider.t.sol (deliberately not inherited).
contract V3ProviderRebalanceLeakTest is Test {
  using MarketParamsLib for MarketParams;
  using stdStorage for StdStorage;

  address constant POOL = 0xe1B404Aaf60eEc5c8A1FEDE7dcDC0EAb9C69662F;
  address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
  uint24 constant FEE = 100;

  address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // token0
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // token1
  address constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant RANGE_LOWER_BPS = 50;
  uint256 constant RANGE_UPPER_BPS = 50;
  uint256 constant LLTV = 70 * 1e16;
  uint256 constant BNB_USD = 600e8;

  Moolah moolah;
  SlisBNBV3Provider provider;
  SlisBNBV3DexAdapter adapter;
  V3ProviderLens lens;
  SlisBNBV3ProviderOracle providerOracle;
  LeakMockOracle oracle;
  LeakMockSwap mockSwap;
  MarketParams marketParams;
  Id marketId;

  uint256 slisPrice;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);

    oracle = new LeakMockOracle();
    slisPrice = (BNB_USD * rate) / 1e18;
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, slisPrice);
    oracle.setPrice(LISUSD, 1e8);

    LeakMockStakeManager mockSm = new LeakMockStakeManager(rate, SLISBNB);
    vm.etch(STAKE_MANAGER, address(mockSm).code);
    vm.deal(STAKE_MANAGER, 1_000_000 ether);
    deal(SLISBNB, STAKE_MANAGER, 1_000_000 ether);

    SlisBNBV3DexAdapter adapterImpl = new SlisBNBV3DexAdapter(NPM, SLISBNB, WBNB, FEE, TWAP_PERIOD);
    adapter = SlisBNBV3DexAdapter(
      payable(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeCall(SlisBNBV3DexAdapter.initialize, (admin, manager, RANGE_LOWER_BPS, RANGE_UPPER_BPS))
        )
      )
    );

    SlisBNBV3Provider provImpl = new SlisBNBV3Provider(MOOLAH_PROXY, address(adapter));
    provider = SlisBNBV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            SlisBNBV3Provider.initialize,
            (admin, manager, bot, address(oracle), WBNB, "SlisBNBV3Provider slisBNB/WBNB", "v3LP-slisBNB-WBNB")
          )
        )
      )
    );

    vm.prank(admin);
    adapter.setProvider(address(provider));

    mockSwap = new LeakMockSwap();
    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(mockSwap), true);

    SlisBNBV3ProviderOracle oracleImpl = new SlisBNBV3ProviderOracle(
      address(adapter),
      address(provider),
      SLISBNB,
      WBNB
    );
    providerOracle = SlisBNBV3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeCall(V3ProviderOracle.initialize, (admin, manager, address(oracle), uint256(0)))
        )
      )
    );

    address newImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

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

    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");

    lens = new V3ProviderLens(address(provider), address(adapter));
  }

  /* ───────────────────────────── helpers ───────────────────────────── */

  function _deposit(
    address _user,
    uint256 amount0,
    uint256 amount1
  ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(SLISBNB, _user, amount0);
    deal(WBNB, _user, amount1);
    (, uint256 exp0, uint256 exp1) = lens.previewDepositAmounts(amount0, amount1);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;
    uint256 minShares = (lens.previewDepositShares(amount0, amount1) * 999) / 1000;
    vm.startPrank(_user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(marketParams, amount0, amount1, min0, min1, minShares, _user);
    vm.stopPrank();
  }

  /// @dev Total position value in 8-decimal USD at the adapter's FAIR price, via live `oracle.peek()`
  ///      (never the fixture's hard-coded `_valueUSD`). Mirrors V3Provider._positionValueUsd.
  function _fairNavUsd() internal view returns (uint256) {
    (uint256 t0, uint256 t1) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
    return (t0 * oracle.peek(SLISBNB)) / 1e18 + (t1 * oracle.peek(WBNB)) / 1e18;
  }

  function _idleValueUsd() internal view returns (uint256) {
    return
      (adapter.idleToken0() * oracle.peek(SLISBNB)) / 1e18 + (adapter.idleToken1() * oracle.peek(WBNB)) / 1e18;
  }

  function _priceFromSqrt(uint160 s) internal pure returns (uint256) {
    return FullMath.mulDiv(uint256(s), uint256(s), 1 << 96);
  }

  /// @dev |spot − fair| as bps of the fair price.
  function _spotDevBps() internal view returns (uint256) {
    uint256 ps = _priceFromSqrt(adapter.spotSqrtPriceX96());
    uint256 pf = _priceFromSqrt(adapter.fairSqrtPriceX96());
    return ps > pf ? ((ps - pf) * 10_000) / pf : ((pf - ps) * 10_000) / pf;
  }

  /// @dev sqrtPriceX96 sitting exactly `devBps` (signed, bps of PRICE) off the rate-anchored fair price.
  function _sqrtAtDevBps(int256 devBps) internal view returns (uint160) {
    uint256 num = uint256(int256(10_000) + devBps);
    uint256 mult = Math.sqrt((num * 1e18) / 10_000); // = sqrt(1 + devBps/1e4) * 1e9
    return uint160(FullMath.mulDiv(uint256(adapter.fairSqrtPriceX96()), mult, 1e9));
  }

  /// @dev Drive the pool spot to exactly `limit` with a real swap (direction picked from the live spot).
  function _parkSpotAt(uint160 limit) internal {
    uint160 cur = adapter.spotSqrtPriceX96();
    if (cur == limit) return;
    LimitSwapper sw = new LimitSwapper();
    if (limit > cur) {
      deal(WBNB, address(sw), 3_000_000 ether);
      sw.swapToLimit(POOL, false, 3_000_000 ether, limit); // token1 in → price up
    } else {
      deal(SLISBNB, address(sw), 3_000_000 ether);
      sw.swapToLimit(POOL, true, 3_000_000 ether, limit); // token0 in → price down
    }
  }

  /// @dev Park the pool spot `devBps` ABOVE fair; returns the original spot so it can be restored.
  function _skewSpotAboveFairBy(uint256 devBps) internal returns (uint160 spotBefore) {
    spotBefore = adapter.spotSqrtPriceX96();
    _parkSpotAt(_sqrtAtDevBps(int256(devBps)));
  }

  /* ══════════════════════════════ M4 ══════════════════════════════ */

  /// @dev Whole-position leak of a BOT rebalance() that opts out of the spot-deviation gate with
  ///      targetSqrtPriceX96 == 0, measured at the FAIR price across {50,100,200,500} bps of spot skew.
  ///      `minLiquidity = 1` is the minimum a hostile BOT must pass to dodge the no-op short-circuit at
  ///      V3DexAdapter.sol:481-499 and reach the real burn → convert → re-mint path.
  function test_m4_rebalanceTargetZero_wholePositionLeak() public {
    console2.log(
      string.concat(
        "M4ENV block=",
        vm.toString(block.number),
        " fair_sqrt=",
        vm.toString(uint256(adapter.fairSqrtPriceX96())),
        " spot_sqrt=",
        vm.toString(uint256(adapter.spotSqrtPriceX96())),
        " live_dev_bps=",
        vm.toString(_spotDevBps()),
        " tickLower=",
        vm.toString(int256(adapter.tickLower())),
        " tickUpper=",
        vm.toString(int256(adapter.tickUpper())),
        " maxSpotDeviationBps=",
        vm.toString(adapter.maxSpotDeviationBps()),
        " maxRebalanceLossBp=",
        vm.toString(provider.maxRebalanceLossBp()),
        " maxDailyLossUsd=",
        vm.toString(provider.maxDailyLossUsd())
      )
    );
    _parkSpotAt(_sqrtAtDevBps(0)); // centre on fair so the starting position is balanced
    _deposit(user, 100 ether, 100 ether);
    (uint256 t0, uint256 t1) = lens.getFairComposition();
    _deposit(user2, t0 / 2, t1 / 2); // second victim
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256[4] memory deltas = [uint256(50), 100, 200, 500];
    for (uint256 i = 0; i < deltas.length; i++) {
      uint256 snap = vm.snapshotState();
      _m4Case(deltas[i], 0, "target=0");
      vm.revertToState(snap);
    }
  }

  /// @dev Control arm: the SAME skew with a CORRECT target (= live spot) and with a DEVIATED target,
  ///      to show what the gate at V3DexAdapter.sol:553-560 does when it is not opted out of.
  function test_m4_controlTargets_correctAndDeviated() public {
    _parkSpotAt(_sqrtAtDevBps(0));
    _deposit(user, 100 ether, 100 ether);
    (uint256 t0, uint256 t1) = lens.getFairComposition();
    _deposit(user2, t0 / 2, t1 / 2);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256[4] memory deltas = [uint256(50), 100, 200, 500];
    for (uint256 i = 0; i < deltas.length; i++) {
      uint256 snap = vm.snapshotState();
      _m4Case(deltas[i], 1, "target=spot");
      vm.revertToState(snap);

      snap = vm.snapshotState();
      _m4Case(deltas[i], 2, "target=fair");
      vm.revertToState(snap);
    }
  }

  /// @param mode 0 = target 0 (opt-out), 1 = target == live spot, 2 = target == fair (deviated target)
  function _m4Case(uint256 deltaBps, uint256 mode, string memory label) internal {
    uint256 vPre = _fairNavUsd();
    uint256 idleBpsPre = (_idleValueUsd() * 10_000) / vPre;
    _skewSpotAboveFairBy(deltaBps);
    uint256 achieved = _spotDevBps();
    uint256 vSkewed = _fairNavUsd();

    uint160 target;
    if (mode == 1) target = adapter.spotSqrtPriceX96();
    else if (mode == 2) target = adapter.fairSqrtPriceX96();

    bool reverted;
    string memory reason = "-";
    vm.prank(bot);
    try provider.rebalance(0, 0, 1, target, 0, block.timestamp, "") {} catch (bytes memory err) {
      reverted = true;
      reason = _selectorName(err);
    }

    uint256 vAfter = _fairNavUsd();
    console2.log(
      string.concat(
        "M4 delta_bps=",
        vm.toString(deltaBps),
        " achieved_dev_bps=",
        vm.toString(achieved),
        " ",
        label,
        " idle_bps_pre=",
        vm.toString(idleBpsPre),
        " v_pre_skew=",
        vm.toString(vPre),
        " v_before=",
        vm.toString(vSkewed),
        " v_after=",
        vm.toString(vAfter),
        " loss_usd_8dp=",
        vAfter <= vSkewed ? vm.toString(vSkewed - vAfter) : string.concat("-", vm.toString(vAfter - vSkewed)),
        " loss_bps_vs_skewed=",
        _lossBps(vSkewed, vAfter),
        " loss_bps_vs_pre_skew=",
        _lossBps(vPre, vAfter),
        " reverted=",
        reverted ? reason : "false"
      )
    );
  }

  /// @dev Signed loss in bps rendered as a string (negative = the fair NAV went UP).
  function _lossBps(uint256 before, uint256 aft) internal pure returns (string memory) {
    if (before == 0) return "n/a";
    if (aft <= before) return vm.toString(((before - aft) * 10_000) / before);
    return string.concat("-", vm.toString(((aft - before) * 10_000) / before));
  }

  function _selectorName(bytes memory err) internal pure returns (string memory) {
    if (err.length < 4) return "unknown";
    bytes4 sel = bytes4(err[0]) | (bytes4(err[1]) >> 8) | (bytes4(err[2]) >> 16) | (bytes4(err[3]) >> 24);
    if (sel == V3DexAdapter.SpotDeviationTooHigh.selector) return "SpotDeviationTooHigh";
    if (sel == V3Provider.RebalanceLossTooHigh.selector) return "RebalanceLossTooHigh";
    if (sel == V3Provider.DailyLossExceeded.selector) return "DailyLossExceeded";
    if (sel == V3DexAdapter.InsufficientLiquidityMinted.selector) return "InsufficientLiquidityMinted";
    if (sel == V3DexAdapter.SwapLossTooHigh.selector) return "SwapLossTooHigh"; // 0xd0029dc5
    return string.concat("other:", vm.toString(abi.encodePacked(sel)));
  }

  /// @dev Round-trip arm: the instantaneous fair-NAV check both this test and _guardedRebalance perform
  ///      is taken at a skewed spot. This measures the damage that only materialises once the attacker
  ///      unwinds the skew, against the identical no-rebalance control.
  function test_m4_roundTripDamage_vsNoRebalanceControl() public {
    _parkSpotAt(_sqrtAtDevBps(0));
    _deposit(user, 100 ether, 100 ether);
    (uint256 t0, uint256 t1) = lens.getFairComposition();
    _deposit(user2, t0 / 2, t1 / 2);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256[4] memory deltas = [uint256(50), 100, 200, 500];
    for (uint256 i = 0; i < deltas.length; i++) {
      uint256 snap = vm.snapshotState();
      uint256 vPre = _fairNavUsd();

      // control: skew, NO rebalance, restore the spot
      uint160 spot0 = _skewSpotAboveFairBy(deltas[i]);
      _parkSpotAt(spot0);
      uint256 vControl = _fairNavUsd();
      vm.revertToState(snap);

      snap = vm.snapshotState();
      // attack: skew, rebalance(target=0), restore the spot
      uint160 spot1 = _skewSpotAboveFairBy(deltas[i]);
      bool reverted;
      vm.prank(bot);
      try provider.rebalance(0, 0, 1, 0, 0, block.timestamp, "") {} catch {
        reverted = true;
      }
      _parkSpotAt(spot1);
      uint256 vAttack = _fairNavUsd();

      console2.log(
        string.concat(
          "M4RT delta_bps=",
          vm.toString(deltas[i]),
          " v_pre=",
          vm.toString(vPre),
          " v_control_roundtrip=",
          vm.toString(vControl),
          " v_attack_roundtrip=",
          vm.toString(vAttack),
          " marginal_loss_bps=",
          _lossBps(vControl, vAttack),
          " reverted=",
          reverted ? "true" : "false"
        )
      );
      vm.revertToState(snap);
    }
  }

  /// @dev Encode a token0→token1 rebalance swap through the whitelisted mock venue paying exactly
  ///      `amountOut` (amountOutMin = 0, i.e. the BOT's own slippage floor disabled).
  function _sellToken0Data(uint256 amountIn, uint256 amountOut) internal returns (bytes memory) {
    deal(WBNB, address(mockSwap), amountOut);
    bytes memory inner = abi.encodeCall(LeakMockSwap.swap, (SLISBNB, WBNB, amountIn, amountOut, address(adapter)));
    return abi.encode(address(mockSwap), true, amountIn, uint256(0), false, inner);
  }

  /// @dev How much can a compromised BOT ACTUALLY bleed per rebalance while opting out of the
  ///      spot-deviation gate (targetSqrtPriceX96 == 0)? Sweeps the venue underpayment and records which
  ///      cap fires: maxSwapLossBp (adapter, 5% of the swapped leg) → maxRebalanceLossBp (2% of fair NAV)
  ///      → maxDailyLossUsd (1000 USD/day). No skew: this isolates the CAP ceiling, not the skew.
  function test_m4_lossCapCeiling_withTargetZeroAndHostileSwap() public {
    _parkSpotAt(_sqrtAtDevBps(0));
    _deposit(user, 100 ether, 100 ether);
    (uint256 c0, uint256 c1) = lens.getFairComposition();
    _deposit(user2, c0 / 2, c1 / 2);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256 nav = _fairNavUsd();
    console2.log(
      string.concat(
        "M4CAP nav_usd_8dp=",
        vm.toString(nav),
        " cap_perRebalance_usd_8dp=",
        vm.toString((nav * provider.maxRebalanceLossBp()) / 1e6),
        " cap_daily_usd_8dp=",
        vm.toString(provider.maxDailyLossUsd()),
        " cap_perSwap_bp_ppm=",
        vm.toString(adapter.maxSwapLossBp())
      )
    );

    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256[5] memory underpayBps = [uint256(50), 100, 200, 500, 1000];
    for (uint256 i = 0; i < underpayBps.length; i++) {
      uint256 snap = vm.snapshotState();
      (uint256 t0, ) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
      uint256 amountIn = (t0 * 80) / 100;
      uint256 fairOut = (amountIn * rate) / 1e18;
      uint256 amountOut = (fairOut * (10_000 - underpayBps[i])) / 10_000;
      bytes memory data = _sellToken0Data(amountIn, amountOut);

      uint256 vBefore = _fairNavUsd();
      bool reverted;
      string memory reason = "false";
      vm.prank(bot);
      try provider.rebalance(0, 0, 1, 0, 0, block.timestamp, data) {} catch (bytes memory err) {
        reverted = true;
        reason = _selectorName(err);
      }
      uint256 vAfter = _fairNavUsd();
      console2.log(
        string.concat(
          "M4CAP underpay_bps=",
          vm.toString(underpayBps[i]),
          " swapped_frac_of_token0_pct=80 v_before=",
          vm.toString(vBefore),
          " v_after=",
          vm.toString(vAfter),
          " realized_loss_usd_8dp=",
          vAfter <= vBefore ? vm.toString(vBefore - vAfter) : string.concat("-", vm.toString(vAfter - vBefore)),
          " loss_bps=",
          _lossBps(vBefore, vAfter),
          " reverted=",
          reason
        )
      );
      vm.revertToState(snap);
    }
  }

  /* ══════════════════════════════ M5 ══════════════════════════════ */

  /// @dev alpha*F idle fee dilution. user deposits (all deployed into the pool); user2 deposits a sized
  ///      amount that lands purely in IDLE (the subsequent-deposit path credits idle, never mints), so
  ///      alpha = idle/(deployed+idle) is dialled to {10,25,50}%. Real pool swaps then earn REAL fees F
  ///      for the deployed position; F is measured as the increment of positionAmountsAt(fair) (which is
  ///      exactly the `_pendingFees` increment — liquidity, tokensOwed and idle are all unchanged by a
  ///      swap), and user2's slice of it is compared against alpha*F.
  function test_m5_idleFeeDilution_alphaTimesF() public {
    uint256[3] memory alphas = [uint256(1000), 2500, 5000];
    for (uint256 i = 0; i < alphas.length; i++) {
      uint256 snap = vm.snapshotState();
      _m5Case(alphas[i]);
      vm.revertToState(snap);
    }
  }

  function _m5Case(uint256 alphaBpsTarget) internal {
    _parkSpotAt(_sqrtAtDevBps(0)); // centre on fair: deposit credit is min(fair, spot)
    _deposit(user, 100 ether, 100 ether);
    assertEq(adapter.idleToken0(), 0, "first deposit deploys, leaves no idle");
    assertEq(adapter.idleToken1(), 0, "first deposit deploys, leaves no idle");

    // k = alpha / (1 - alpha) of the current fair composition → a pure-idle deposit of that size.
    _parkSpotAt(_sqrtAtDevBps(0));
    (uint256 t0, uint256 t1) = lens.getFairComposition();
    uint256 k0 = (t0 * alphaBpsTarget) / (10_000 - alphaBpsTarget);
    uint256 k1 = (t1 * alphaBpsTarget) / (10_000 - alphaBpsTarget);
    (uint256 shares2, , ) = _deposit(user2, k0, k1);

    uint256 supply = provider.totalSupply();
    uint256 navStart = _fairNavUsd();
    uint256 alphaBps = (_idleValueUsd() * 10_000) / navStart;
    (uint256 s0, uint256 s1) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
    uint256 u2Start = (shares2 * navStart) / supply;

    _churnFees();

    uint256 navEnd = _fairNavUsd();
    (uint256 e0, uint256 e1) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
    uint256 u2End = (shares2 * navEnd) / supply;

    uint256 fUsd = navEnd - navStart;
    uint256 measured = u2End - u2Start;
    uint256 predicted = (alphaBps * fUsd) / 10_000;
    uint256 relErr = predicted == 0 ? 0 : ((measured > predicted ? measured - predicted : predicted - measured) *
      10_000) / predicted;
    // Same prediction with alpha carried at 1e9 precision instead of truncated to whole bps — isolates
    // how much of relErr is just the rounding of alpha in the log line above.
    uint256 alphaPpb = (_idleValueUsd() * 1e9) / navStart;
    uint256 predictedPpb = (alphaPpb * fUsd) / 1e9;
    uint256 relErrPpb = predictedPpb == 0
      ? 0
      : ((measured > predictedPpb ? measured - predictedPpb : predictedPpb - measured) * 10_000) / predictedPpb;

    console2.log(
      string.concat(
        "M5 alpha_bps=",
        vm.toString(alphaBps),
        " share_frac_bps=",
        vm.toString((shares2 * 10_000) / supply),
        " fees_F0=",
        vm.toString(e0 - s0),
        " fees_F1=",
        vm.toString(e1 - s1),
        " fees_F=",
        vm.toString(fUsd),
        " user2_share_of_F=",
        vm.toString(measured),
        " predicted_alpha_F=",
        vm.toString(predicted),
        " rel_err_bps=",
        vm.toString(relErr),
        " alpha_ppb=",
        vm.toString(alphaPpb),
        " predicted_alphaPpb_F=",
        vm.toString(predictedPpb),
        " rel_err_bps_ppb=",
        vm.toString(relErrPpb),
        " nav_start=",
        vm.toString(navStart)
      )
    );
    assertGt(fUsd, 0, "the churn must earn real fees, otherwise the measurement is vacuous");
  }

  /// @dev The already-verified boundary, re-measured: a late depositor cannot capture fees that are
  ///      ALREADY pending, because the deposit quote values the position at positionAmountsAt(fair)
  ///      which already includes them. user2 pays in `I` and is worth `I` right after — the pre-existing
  ///      F stays with the incumbent. Only fees earned AFTER the deposit are shared (that is M5).
  function test_m5_depositCannotCaptureAlreadyPendingFees() public {
    _parkSpotAt(_sqrtAtDevBps(0)); // start centred on fair
    _deposit(user, 100 ether, 100 ether);
    _churnFees(); // build up pending fees BEFORE user2 arrives
    // The churn leaves the spot off fair; deposit credit is min(fair, spot), so re-centre before user2
    // deposits — otherwise the measurement is contaminated by the (separate, intended) skew haircut.
    _parkSpotAt(_sqrtAtDevBps(0));
    uint256 navPre = _fairNavUsd();

    (uint256 t0, uint256 t1) = lens.getFairComposition();
    (uint256 shares2, uint256 used0, uint256 used1) = _deposit(user2, t0 / 2, t1 / 2);

    uint256 contributed = (used0 * oracle.peek(SLISBNB)) / 1e18 + (used1 * oracle.peek(WBNB)) / 1e18;
    uint256 navPost = _fairNavUsd();
    uint256 u2Value = (shares2 * navPost) / provider.totalSupply();
    console2.log(
      string.concat(
        "M5BOUND nav_pre_deposit=",
        vm.toString(navPre),
        " user2_contributed=",
        vm.toString(contributed),
        " user2_value_after=",
        vm.toString(u2Value),
        " capture_bps=",
        _lossBps(contributed, u2Value)
      )
    );
  }

  /// @dev Generate REAL pool fees for the managed position: round-trip the spot inside the ±0.5% range
  ///      (1 tick ≈ 1 bp) so the position stays in range and collects its pro-rata share of the 1bp fee.
  function _churnFees() internal {
    uint160 up = _sqrtAtDevBps(40);
    uint160 down = _sqrtAtDevBps(-40);
    for (uint256 i = 0; i < 10; i++) {
      _parkSpotAt(up);
      _parkSpotAt(down);
    }
  }
}

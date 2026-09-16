// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SlisBNBV3Provider } from "../../src/provider/v3/SlisBNBV3Provider.sol";
import { SlisBNBV3DexAdapter } from "../../src/provider/v3/SlisBNBV3DexAdapter.sol";
import { SlisBNBV3ProviderOracle } from "../../src/provider/v3/SlisBNBV3ProviderOracle.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { V3ProviderLens } from "../../src/provider/v3/V3ProviderLens.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";
import { IV3PoolMinimal } from "../../src/provider/interfaces/IV3PoolMinimal.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TokenConfig, IOracle } from "moolah/interfaces/IOracle.sol";

/// @dev Minimal resilient-oracle mock: 8-decimal USD prices, settable per token.
contract MeasOracle is IOracle {
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

/// @dev StakeManager stand-in at a fixed rate (seeded from the live rate), same shape as the one the
///      functional fixture etches — `instantWithdraw` does not exist on the live impl at this block.
contract MeasStakeManager {
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

/// @dev Pool swapper that stops EXACTLY at a caller-supplied sqrtPriceLimitX96, so the pool spot can be
///      placed at a precise target price instead of "some large swap". Pays the V3 callback in full.
contract LimitSwapper {
  function swapToLimit(address pool, bool zeroForOne, uint256 amountIn, uint160 limit) external {
    IListaV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool));
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    _pay(amount0Delta, amount1Delta, data);
  }

  function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    _pay(amount0Delta, amount1Delta, data);
  }

  function _pay(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
    address pool = abi.decode(data, (address));
    if (amount0Delta > 0) IERC20(IListaV3Pool(pool).token0()).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(IListaV3Pool(pool).token1()).transfer(msg.sender, uint256(amount1Delta));
  }
}

/// @notice MEASUREMENT-ONLY harness for the V3Provider redemption-leg leak. Nothing here asserts a fix;
///         every test prints one grep-able line per data point so the numbers can be read off the
///         `forge test -vv` output. `src/` is untouched — this measures the CURRENT behaviour.
contract V3ProviderLeakMeasureTest is Test {
  using MarketParamsLib for MarketParams;
  using stdStorage for StdStorage;

  /* ─────────────────── PancakeSwap V3 slisBNB/WBNB 1bp ─────────────────── */
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

  /// @dev Rounding slack for the value invariants, in the `_v` scale (1 USD = 1e26 there). The adapter's
  ///      cap compares 8-decimal USD values, so every truncation inside it is worth 1e-8 USD = 1e18 here;
  ///      4 of them covers both legs of both the entitlement and the delivered basket. That is ~13 orders
  ///      of magnitude below the leaks asserted away (a 12 bps leak on this fixture is ~1e28).
  uint256 constant VALUE_SLACK = 4e18;

  /// @dev MIN/MAX sqrt ratio guards (ticks ±887272) — clamp targets so the pool's own range check passes.
  uint160 constant MIN_SQRT_RATIO = 4295128739;
  uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  Moolah moolah;
  SlisBNBV3Provider provider;
  SlisBNBV3DexAdapter adapter;
  V3ProviderLens lens;
  SlisBNBV3ProviderOracle providerOracle;
  MeasOracle oracle;
  MarketParams marketParams;
  Id marketId;

  uint256 slisPrice;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  /// @dev The WBNB leg is delivered as NATIVE BNB by the adapter, so every redeem receiver needs this.
  receive() external payable {}

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);

    oracle = new MeasOracle();
    slisPrice = (BNB_USD * rate) / 1e18;
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, slisPrice);
    oracle.setPrice(LISUSD, 1e8);

    MeasStakeManager mockSm = new MeasStakeManager(rate, SLISBNB);
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

    deal(LISUSD, address(this), 5_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");

    lens = new V3ProviderLens(address(provider), address(adapter));
  }

  /* ───────────────────────────── helpers ───────────────────────────── */

  function _depositTo(
    MarketParams memory p,
    address _user,
    uint256 amount0,
    uint256 amount1
  ) internal returns (uint256 shares) {
    deal(SLISBNB, _user, amount0);
    deal(WBNB, _user, amount1);
    vm.startPrank(_user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, , ) = provider.deposit(p, amount0, amount1, 0, 0, 0, _user);
    vm.stopPrank();
  }

  function _collateralIn(Id id, address _user) internal view returns (uint256) {
    (, , uint256 col) = moolah.position(id, _user);
    return col;
  }

  /// @dev USD value in a fixed 1e26 scale (raw amount[1e18] × oracle price[1e8]); no division, so the
  ///      bps ratios below lose nothing to rounding. Uses the CURRENT oracle prices (fair, rate-derived).
  function _v(uint256 amount0, uint256 amount1) internal view returns (uint256) {
    return amount0 * oracle.peek(SLISBNB) + amount1 * oracle.peek(WBNB);
  }

  /// @dev Signed (spot − fair)/fair in bps, derived from the two sqrt prices.
  function _signedDeltaBps(uint160 sp, uint160 fp) internal pure returns (int256) {
    uint256 r = (uint256(sp) * 1e18) / uint256(fp); // sqrt ratio, 1e18
    uint256 pr = (r * r) / 1e18; // price ratio, 1e18
    if (pr >= 1e18) return int256(((pr - 1e18) * 10_000) / 1e18);
    return -int256(((1e18 - pr) * 10_000) / 1e18);
  }

  /// @dev Same, in ppm (0.01 bp resolution) — the bps figure truncates and hides sub-bp targeting error.
  function _signedDeltaPpm(uint160 sp, uint160 fp) internal pure returns (int256) {
    uint256 r = (uint256(sp) * 1e18) / uint256(fp);
    uint256 pr = (r * r) / 1e18;
    if (pr >= 1e18) return int256(((pr - 1e18) * 1_000_000) / 1e18);
    return -int256(((1e18 - pr) * 1_000_000) / 1e18);
  }

  /// @dev sqrtPriceX96 that is exactly `deltaBps` (signed, in price terms) away from the fair price.
  function _sqrtTargetFromFair(int256 deltaBps) internal view returns (uint160) {
    uint160 fp = adapter.fairSqrtPriceX96();
    uint256 factor = deltaBps >= 0 ? 10_000 + uint256(deltaBps) : 10_000 - uint256(-deltaBps);
    uint256 sq = Math.sqrt((factor * 1e36) / 10_000); // ≈1e18 scale
    uint256 target = (uint256(fp) * sq) / 1e18;
    if (target <= MIN_SQRT_RATIO) target = uint256(MIN_SQRT_RATIO) + 1;
    if (target >= MAX_SQRT_RATIO) target = uint256(MAX_SQRT_RATIO) - 1;
    return uint160(target);
  }

  /// @dev Walk the pool spot to `target` exactly (V3 stops at the limit when the input is sufficient).
  ///      Returns what the move COST the mover, in the same 1e26 fair-USD scale as `_v` — i.e. fair
  ///      value of the tokens handed to the pool minus fair value of the tokens taken back out. This is
  ///      the denominator for "is the redemption leak actually extractable".
  function _pushSpotTo(uint160 target) internal returns (uint256 costUsd) {
    uint160 cur = adapter.spotSqrtPriceX96();
    if (target == cur) return 0;
    bool zeroForOne = target < cur;
    LimitSwapper sw = new LimitSwapper();
    address tokenIn = zeroForOne ? SLISBNB : WBNB;
    uint256 amountIn = 3_000_000 ether;
    deal(tokenIn, address(sw), amountIn);
    uint256 vBefore = _v(IERC20(SLISBNB).balanceOf(address(sw)), IERC20(WBNB).balanceOf(address(sw)));
    sw.swapToLimit(POOL, zeroForOne, amountIn, target);
    uint256 vAfter = _v(IERC20(SLISBNB).balanceOf(address(sw)), IERC20(WBNB).balanceOf(address(sw)));
    costUsd = vBefore > vAfter ? vBefore - vAfter : 0;
  }

  function _alignSpotToFair() internal {
    _pushSpotTo(adapter.fairSqrtPriceX96());
  }

  /// @dev Two holders + a fully deployed position: user's deposit mints the NFT, user2's deposit parks
  ///      idle (subsequent deposits never mint), and the BOT compound deploys that idle at spot==fair so
  ///      the measured position is price-sensitive rather than half price-insensitive idle.
  function _buildTwoHolderPosition(MarketParams memory p, uint256 amount) internal {
    _alignSpotToFair();
    _depositTo(p, user, amount, amount);
    _depositTo(p, user2, amount, amount);
    vm.prank(bot);
    provider.compound(0, 0);
    _alignSpotToFair();
  }

  /// @dev Share of the fair-priced position that is price-INSENSITIVE (idle + owed + pending fees). Any
  ///      such share dilutes every leak/discount ratio below, so it is reported alongside them.
  function _nonPositionShareBps() internal view returns (uint256) {
    uint160 fp = adapter.fairSqrtPriceX96();
    (uint256 t0, uint256 t1) = adapter.positionAmountsAt(fp);
    (uint256 p0, uint256 p1) = adapter.amountsForLiquidity(adapter.totalLiquidity(), fp);
    uint256 total = _v(t0, t1);
    uint256 principal = _v(p0, p1);
    if (total == 0) return 0;
    return ((total - principal) * 10_000) / total;
  }

  function _bps(uint256 a, uint256 b) internal pure returns (int256) {
    // (a − b) / b in bps, signed.
    if (a >= b) return int256(((a - b) * 10_000) / b);
    return -int256(((b - a) * 10_000) / b);
  }

  function _ppm(uint256 a, uint256 b) internal pure returns (int256) {
    if (a >= b) return int256(((a - b) * 1_000_000) / b);
    return -int256(((b - a) * 1_000_000) / b);
  }

  /// @dev num / den in bps — for costs whose natural denominator is neither `a` nor `b`.
  function _fracBps(uint256 num, uint256 den) internal pure returns (int256) {
    return int256((num * 10_000) / den);
  }

  /// @dev (a − b) / a in ppm — the margin expressed over the SEIZED value, i.e. the same denominator
  ///      Moolah's tolerable-discount bound `1 − 1/I` uses. `_ppm` uses `b` as the denominator instead.
  function _marginPpm(uint256 a, uint256 b) internal pure returns (int256) {
    if (a >= b) return int256(((a - b) * 1_000_000) / a);
    return -int256(((b - a) * 1_000_000) / a);
  }

  /* ──────────────────────── M0: fork baseline ──────────────────────── */

  function test_measure_forkBaseline() public {
    uint160 fp = adapter.fairSqrtPriceX96();
    uint160 sp = adapter.spotSqrtPriceX96();
    console2.log(
      string.concat(
        "M0 fair_sqrt=",
        vm.toString(uint256(fp)),
        " spot_sqrt=",
        vm.toString(uint256(sp)),
        " spot_vs_fair_bps=",
        vm.toString(_signedDeltaBps(sp, fp)),
        " stake_rate=",
        vm.toString(IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18)),
        " slis_usd=",
        vm.toString(slisPrice)
      )
    );

    _buildTwoHolderPosition(marketParams, 100 ether);

    fp = adapter.fairSqrtPriceX96();
    sp = adapter.spotSqrtPriceX96();
    (uint256 t0, uint256 t1) = adapter.positionAmountsAt(fp);
    console2.log(
      string.concat(
        "M0 built tickLower=",
        vm.toString(int256(adapter.tickLower())),
        " tickUpper=",
        vm.toString(int256(adapter.tickUpper())),
        " aligned_bps=",
        vm.toString(_signedDeltaBps(sp, fp)),
        " total0=",
        vm.toString(t0),
        " total1=",
        vm.toString(t1),
        " liq=",
        vm.toString(uint256(adapter.totalLiquidity())),
        " idle0=",
        vm.toString(adapter.idleToken0()),
        " idle1=",
        vm.toString(adapter.idleToken1()),
        " nonpos_bps=",
        vm.toString(_nonPositionShareBps())
      )
    );
    console2.log(
      string.concat(
        "M0 supply=",
        vm.toString(provider.totalSupply()),
        " col_user=",
        vm.toString(_collateralIn(marketId, user)),
        " col_user2=",
        vm.toString(_collateralIn(marketId, user2))
      )
    );
  }

  /* ─────────── M1 + M2: redemption leak curve / operator discounts ─────────── */

  function test_measure_redeemLeakAndOperatorDiscounts() public {
    int256[7] memory mags = [int256(0), 10, 25, 50, 100, 200, 500];

    for (uint256 d = 0; d < 2; d++) {
      bool up = d == 0;
      for (uint256 i = 0; i < mags.length; i++) {
        if (mags[i] == 0 && !up) continue; // δ=0 baseline is direction-free; measure it once
        _measurePoint(up ? mags[i] : -mags[i], up ? "up" : "down");
      }
    }
  }

  /// @dev One measured data point. Kept in a struct so the via-IR stack stays shallow.
  struct Pt {
    int256 target;
    int256 achieved;
    int256 achievedPpm;
    uint256 shares;
    uint256 supply;
    uint256 nonpos;
    uint256 vEnt;
    uint256 vDel;
    uint256 vA;
    uint256 vB;
    uint256 vSpotPro;
    uint256 p0f;
    uint256 p1f;
    uint256 p0s;
    uint256 p1s;
    uint256 out0;
    uint256 out1;
    uint256 pxBefore;
    uint256 pxAfter;
    uint256 shares2;
    uint256 vEnt2Pre;
    uint256 vDel2;
    uint256 out20;
    uint256 out21;
    uint256 pushCost;
  }

  function _measurePoint(int256 targetDelta, string memory dir) internal {
    uint256 snap = vm.snapshotState();

    _buildTwoHolderPosition(marketParams, 100 ether);

    Pt memory pt;
    pt.target = targetDelta;
    _snapshotRetainedHolder(pt); // user2's fair entitlement BEFORE any skew

    pt.pushCost = _pushSpotTo(_sqrtTargetFromFair(targetDelta));
    _snapshotComposition(pt);
    _computeOperators(pt);

    // ── M1 (real withdraw against the unmodified src) ──
    // The vLP share price is fair-composition based, so its move across the withdraw is the direct
    // measure of what the RETAINED holder (user2) loses — the leak's victim.
    pt.pxBefore = providerOracle.peek(address(provider));
    vm.prank(user);
    (pt.out0, pt.out1) = provider.withdraw(marketParams, pt.shares, 0, 0, user, user);
    pt.pxAfter = providerOracle.peek(address(provider));
    pt.vDel = _v(pt.out0, pt.out1);

    // Victim check: put the pool back at fair and cash the retained holder out in full. If the exit
    // above really transferred value away from user2, this is where it shows up as missing tokens.
    _alignSpotToFair();
    vm.prank(user2);
    (pt.out20, pt.out21) = provider.withdraw(marketParams, pt.shares2, 0, 0, user2, user2);
    pt.vDel2 = _v(pt.out20, pt.out21);

    _logM1(pt, dir);
    _logM2(pt, dir);
    _logM1Raw(pt, dir);
    _logM1Victim(pt, dir);

    vm.revertToState(snap);
  }

  function _snapshotRetainedHolder(Pt memory pt) internal view {
    (uint256 x0, uint256 y0) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
    pt.shares2 = _collateralIn(marketId, user2);
    pt.vEnt2Pre = (_v(x0, y0) * pt.shares2) / provider.totalSupply();
  }

  function _logM1Victim(Pt memory pt, string memory dir) internal view {
    console2.log(
      string.concat(
        "M1v dir=",
        dir,
        " target_bps=",
        vm.toString(pt.target),
        " v_u2_entitled_pre=",
        vm.toString(pt.vEnt2Pre),
        " v_u2_delivered=",
        vm.toString(pt.vDel2),
        " u2_delta_ppm=",
        vm.toString(_ppm(pt.vDel2, pt.vEnt2Pre)),
        " u2_out0=",
        vm.toString(pt.out20),
        " u2_out1=",
        vm.toString(pt.out21),
        " push_cost=",
        vm.toString(pt.pushCost),
        " leak_gain=",
        vm.toString(pt.vDel > pt.vEnt ? pt.vDel - pt.vEnt : 0)
      )
    );
  }

  function _snapshotComposition(Pt memory pt) internal view {
    uint160 fp = adapter.fairSqrtPriceX96();
    uint160 sp = adapter.spotSqrtPriceX96();
    pt.achieved = _signedDeltaBps(sp, fp);
    pt.achievedPpm = _signedDeltaPpm(sp, fp);
    pt.supply = provider.totalSupply();
    pt.shares = _collateralIn(marketId, user);
    pt.nonpos = _nonPositionShareBps();

    (uint256 xf, uint256 yf) = adapter.positionAmountsAt(fp);
    (uint256 xs, uint256 ys) = adapter.positionAmountsAt(sp);
    pt.vEnt = (_v(xf, yf) * pt.shares) / pt.supply;
    pt.p0f = (xf * pt.shares) / pt.supply;
    pt.p1f = (yf * pt.shares) / pt.supply;
    pt.p0s = (xs * pt.shares) / pt.supply;
    pt.p1s = (ys * pt.shares) / pt.supply;
  }

  /// @dev M2: what operator A (per-leg min) and operator B (value scaling) would have delivered on the
  ///      exact same state. Pure arithmetic — no `src/` change needed to price either candidate.
  function _computeOperators(Pt memory pt) internal view {
    pt.vA = _v(Math.min(pt.p0f, pt.p0s), Math.min(pt.p1f, pt.p1s));
    pt.vSpotPro = _v(pt.p0s, pt.p1s);
    if (pt.vSpotPro > pt.vEnt) {
      uint256 scale = (pt.vEnt * 1e18) / pt.vSpotPro;
      pt.vB = _v((pt.p0s * scale) / 1e18, (pt.p1s * scale) / 1e18);
    } else {
      pt.vB = pt.vSpotPro;
    }
  }

  function _logM1(Pt memory pt, string memory dir) internal view {
    console2.log(
      string.concat(
        "M1 dir=",
        dir,
        " target_bps=",
        vm.toString(pt.target),
        " delta_bps=",
        vm.toString(pt.achieved),
        " delta_ppm=",
        vm.toString(pt.achievedPpm),
        " v_entitled=",
        vm.toString(pt.vEnt),
        " v_delivered=",
        vm.toString(pt.vDel),
        " leak_bps=",
        vm.toString(_bps(pt.vDel, pt.vEnt)),
        " leak_ppm=",
        vm.toString(_ppm(pt.vDel, pt.vEnt)),
        " nonpos_bps=",
        vm.toString(pt.nonpos),
        " px_before=",
        vm.toString(pt.pxBefore),
        " px_after=",
        vm.toString(pt.pxAfter),
        " holder_loss_ppm=",
        vm.toString(-_ppm(pt.pxAfter, pt.pxBefore))
      )
    );
  }

  function _logM2(Pt memory pt, string memory dir) internal view {
    console2.log(
      string.concat(
        "M2 dir=",
        dir,
        " target_bps=",
        vm.toString(pt.target),
        " delta_bps=",
        vm.toString(pt.achieved),
        " opA_discount_bps=",
        vm.toString(-_bps(pt.vA, pt.vEnt)),
        " opA_discount_ppm=",
        vm.toString(-_ppm(pt.vA, pt.vEnt)),
        " opB_discount_bps=",
        vm.toString(-_bps(pt.vB, pt.vEnt)),
        " opB_discount_ppm=",
        vm.toString(-_ppm(pt.vB, pt.vEnt)),
        " opA_exiter_cost_bps=",
        vm.toString(_fracBps(pt.vDel - pt.vA, pt.vEnt)),
        " opB_exiter_cost_ppm=",
        vm.toString(_ppm(pt.vDel, pt.vB)),
        " v_spot_prorata=",
        vm.toString(pt.vSpotPro)
      )
    );
  }

  function _logM1Raw(Pt memory pt, string memory dir) internal view {
    console2.log(
      string.concat(
        "M1raw dir=",
        dir,
        " target_bps=",
        vm.toString(pt.target),
        " out0=",
        vm.toString(pt.out0),
        " out1=",
        vm.toString(pt.out1),
        " fair0=",
        vm.toString(pt.p0f),
        " fair1=",
        vm.toString(pt.p1f),
        " spot0=",
        vm.toString(pt.p0s),
        " spot1=",
        vm.toString(pt.p1s)
      )
    );
  }

  /* ──────── INV1: the redemption leg never out-delivers the fair entitlement ──────── */

  /// @notice Value flows IN at min(fair, spot) but the burn returns the CURRENT spot basket, whose fair
  ///         value has its unique minimum at spot == fair — so ANY skew, in either direction, lets the
  ///         exiter take more than their fair share. The adapter's value cap must close that for every
  ///         δ, while leaving the δ == 0 payout untouched.
  function test_invariant_redeemNeverExceedsFairEntitlement() public {
    int256[6] memory mags = [int256(0), 10, 25, 50, 100, 500];

    for (uint256 d = 0; d < 2; d++) {
      bool up = d == 0;
      for (uint256 i = 0; i < mags.length; i++) {
        if (mags[i] == 0 && !up) continue; // δ=0 is direction-free; assert it once
        _assertNoOverDelivery(up ? mags[i] : -mags[i], up ? "up" : "down");
      }
    }
  }

  function _assertNoOverDelivery(int256 targetDelta, string memory dir) internal {
    uint256 snap = vm.snapshotState();

    _buildTwoHolderPosition(marketParams, 100 ether);
    _pushSpotTo(_sqrtTargetFromFair(targetDelta));

    uint256 supply = provider.totalSupply();
    uint256 shares = _collateralIn(marketId, user);
    (uint256 xf, uint256 yf) = adapter.positionAmountsAt(adapter.fairSqrtPriceX96());
    uint256 vEnt = (_v(xf, yf) * shares) / supply;

    // The preview is what a caller sizes minAmount0/1 from, so it has to quote the CAPPED basket too —
    // otherwise every honest redeem reverts on its own slippage floor.
    (uint256 q0, uint256 q1) = adapter.previewRemoveLiquidity(shares, supply);

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, 0, 0, user, user);
    uint256 vDel = _v(out0, out1);

    string memory tag = string.concat("INV1 dir=", dir, " target_bps=", vm.toString(targetDelta));
    console2.log(
      string.concat(
        tag,
        " delta_bps=",
        vm.toString(_signedDeltaBps(adapter.spotSqrtPriceX96(), adapter.fairSqrtPriceX96())),
        " v_entitled=",
        vm.toString(vEnt),
        " v_delivered=",
        vm.toString(vDel),
        " v_preview=",
        vm.toString(_v(q0, q1)),
        " leak_ppm=",
        vm.toString(_ppm(vDel, vEnt))
      )
    );

    assertLe(vDel, vEnt + VALUE_SLACK, string.concat(tag, ": delivered value exceeds the fair entitlement"));
    assertLe(_v(q0, q1), vEnt + VALUE_SLACK, string.concat(tag, ": preview quotes more than the fair entitlement"));
    if (targetDelta == 0) {
      // spot == fair ⇒ the spot basket IS the fair basket; the cap must be a no-op, not a haircut.
      assertApproxEqAbs(vDel, vEnt, VALUE_SLACK, string.concat(tag, ": delta=0 payout must equal the entitlement"));
    }

    vm.revertToState(snap);
  }

  /* ───────────── M3: real liquidation across the live LLTV tiers ───────────── */

  function test_measure_liquidationAcrossLltvTiers() public {
    uint256[4] memory lltvs = [uint256(965e15), 915e15, 860e15, 800e15];
    int256[3] memory skews = [int256(0), 50, -50];

    for (uint256 i = 0; i < lltvs.length; i++) {
      for (uint256 j = 0; j < skews.length; j++) {
        uint256 snap = vm.snapshotState();
        _measureLiquidation(lltvs[i], skews[j]);
        vm.revertToState(snap);
      }
    }
  }

  /// @notice INV2: capping the redeem must not brick liquidations. At the tightest live tier (lltv 96.5%,
  ///         the thinnest incentive) the realised collateral must still clear the repayment by essentially
  ///         the whole tolerable-discount budget `1 − 1/I`, under no skew and under ±50 bps of skew.
  function test_invariant_liquidationStaysProfitableAtTightestLltv() public {
    int256[3] memory skews = [int256(0), 50, -50];

    for (uint256 j = 0; j < skews.length; j++) {
      uint256 snap = vm.snapshotState();
      Liq memory q = _measureLiquidation(965e15, skews[j]);

      string memory tag = string.concat("INV2 lltv=965e15 skew_bps=", vm.toString(skews[j]));
      assertGt(q.valueOut, q.valueRepaid, string.concat(tag, ": liquidation is unprofitable"));
      assertGe(
        uint256(_marginPpm(q.valueOut, q.valueRepaid)),
        (q.maxTolerablePpm * 999) / 1000,
        string.concat(tag, ": margin fell below 99.9% of the 1 - 1/I budget")
      );

      vm.revertToState(snap);
    }
  }

  /// @dev One liquidation data point (struct-held to keep the via-IR stack shallow).
  struct Liq {
    uint256 lltv;
    int256 skew;
    int256 achieved;
    uint256 borrowed;
    uint256 seized;
    uint256 repaid;
    uint256 out0;
    uint256 out1;
    uint256 valueOut;
    uint256 valueRepaid;
    uint256 valueFair;
    uint256 incentive;
    uint256 maxTolerable;
    uint256 maxTolerablePpm;
    uint256 nonpos;
  }

  function _measureLiquidation(uint256 lltv, int256 skewBps) internal returns (Liq memory q) {
    q.lltv = lltv;
    q.skew = skewBps;

    MarketParams memory p = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: lltv
    });

    _openMarket(p, lltv);
    _buildTwoHolderPosition(p, 100 ether);
    q.borrowed = _borrowToCeiling(p, lltv);

    // Crash the collateral legs 3% (both legs by the same factor, so the rate-consistency invariant
    // between peek(slisBNB) and peek(WBNB) — and hence the fair composition — is preserved).
    oracle.setPrice(SLISBNB, (slisPrice * 97) / 100);
    oracle.setPrice(WBNB, (BNB_USD * 97) / 100);
    oracle.setPrice(BNB_ADDRESS, (BNB_USD * 97) / 100);

    // Put the pool spot `skewBps` away from fair, then liquidate.
    _pushSpotTo(_sqrtTargetFromFair(skewBps));
    q.achieved = _signedDeltaBps(adapter.spotSqrtPriceX96(), adapter.fairSqrtPriceX96());
    q.nonpos = _nonPositionShareBps();

    // Fair-value entitlement of the seized shares, priced BEFORE the seizure changes the market state.
    uint256 cp = moolah._getPrice(p, address(0));
    (q.seized, q.repaid) = moolah.liquidate(p, user, _collateralIn(p.id(), user) / 4, 0, "");
    q.valueFair = ((q.seized * cp) / 1e36) * oracle.peek(LISUSD);

    // Realise the seized collateral: redeem the vLP shares for underlying (what a liquidator must do).
    (q.out0, q.out1) = provider.redeemShares(provider.balanceOf(address(this)), 0, 0, address(this));
    q.valueOut = _v(q.out0, q.out1);
    q.valueRepaid = q.repaid * oracle.peek(LISUSD);

    q.incentive = Math.min(1.15e18, (1e18 * 1e18) / (1e18 - (3e17 * (1e18 - lltv)) / 1e18));
    q.maxTolerable = ((q.incentive - 1e18) * 10_000) / q.incentive;
    q.maxTolerablePpm = ((q.incentive - 1e18) * 1_000_000) / q.incentive;

    _logM3(q);
  }

  function _openMarket(MarketParams memory p, uint256 lltv) internal {
    if (!moolah.isLltvEnabled(lltv)) {
      vm.prank(MANAGER_ADDR);
      moolah.enableLltv(lltv);
    }
    vm.prank(OPERATOR);
    moolah.createMarket(p);
    vm.prank(MANAGER_ADDR);
    moolah.setProvider(p.id(), address(provider), true);
    moolah.supply(p, 1_000_000 ether, 0, address(this), "");
  }

  /// @dev Borrow 99% of the LLTV ceiling so a 3% collateral drawdown tips the position unhealthy.
  function _borrowToCeiling(MarketParams memory p, uint256 lltv) internal returns (uint256 borrowed) {
    uint256 col = _collateralIn(p.id(), user);
    uint256 cp = moolah._getPrice(p, address(0));
    borrowed = ((((col * cp) / 1e36) * lltv) / 1e18) * 99 / 100;
    vm.prank(user);
    moolah.borrow(p, borrowed, 0, user, user);
  }

  function _logM3(Liq memory q) internal view {
    console2.log(
      string.concat(
        "M3 lltv=",
        vm.toString(q.lltv),
        " skew_target_bps=",
        vm.toString(q.skew),
        " delta_bps=",
        vm.toString(q.achieved),
        " I=",
        vm.toString(q.incentive),
        " max_tolerable_bps=",
        vm.toString(q.maxTolerable),
        " max_tolerable_ppm=",
        vm.toString(q.maxTolerablePpm),
        " repaid=",
        vm.toString(q.repaid),
        " seized=",
        vm.toString(q.seized),
        " v_out=",
        vm.toString(q.valueOut),
        " v_repaid=",
        vm.toString(q.valueRepaid),
        " liquidator_profit_bps=",
        vm.toString(_bps(q.valueOut, q.valueRepaid)),
        " liquidator_profit_ppm=",
        vm.toString(_ppm(q.valueOut, q.valueRepaid)),
        " margin_vs_seized_ppm=",
        vm.toString(_marginPpm(q.valueOut, q.valueRepaid)),
        " marginB_vs_seized_ppm=",
        vm.toString(_marginPpm(q.valueFair, q.valueRepaid))
      )
    );
    console2.log(
      string.concat(
        "M3x lltv=",
        vm.toString(q.lltv),
        " skew_target_bps=",
        vm.toString(q.skew),
        " v_fair_entitled=",
        vm.toString(q.valueFair),
        " redeem_overage_bps=",
        vm.toString(_bps(q.valueOut, q.valueFair)),
        " redeem_overage_ppm=",
        vm.toString(_ppm(q.valueOut, q.valueFair)),
        " nonpos_bps=",
        vm.toString(q.nonpos),
        " borrowed=",
        vm.toString(q.borrowed)
      )
    );
  }
}

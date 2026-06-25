// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SlisBNBV3Provider } from "../../src/provider/v3/SlisBNBV3Provider.sol";
import { SlisBNBV3DexAdapter } from "../../src/provider/v3/SlisBNBV3DexAdapter.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";
import { SlisBNBV3ProviderOracle } from "../../src/provider/v3/SlisBNBV3ProviderOracle.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IV3PoolMinimal } from "../../src/provider/interfaces/IV3PoolMinimal.sol";

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

/// @dev Executes a direct pool swap and satisfies the PancakeSwap V3 callback (to manipulate price).
contract PoolSwapper {
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  function swapExactIn(address pool, bool zeroForOne, uint256 amountIn) external {
    uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    IListaV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool));
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    _pay(amount0Delta, amount1Delta, data);
  }

  /// @dev PancakeSwap V3 pools invoke this callback name (not the Uniswap one); support both.
  function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    _pay(amount0Delta, amount1Delta, data);
  }

  function _pay(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
    address pool = abi.decode(data, (address));
    if (amount0Delta > 0) IERC20(IListaV3Pool(pool).token0()).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(IListaV3Pool(pool).token1()).transfer(msg.sender, uint256(amount1Delta));
  }
}

/// @dev Stand-in StakeManager. The live implementation at this fork block predates `instantWithdraw`
///      (the real-time slisBNB→BNB redeem the rebalance inventory conversion relies on), so we etch this
///      faithful mock at the StakeManager address. It mirrors deposit()/instantWithdraw()/convert* at a
///      fixed rate (seeded from the live rate) and performs real BNB↔slisBNB transfers, so the
///      balance-delta accounting in SlisBnbInventoryLib is exercised exactly as it will be in prod.
contract MockStakeManager {
  uint256 public immutable rate; // BNB per slisBNB, 1e18
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

  /// @notice Stake BNB → slisBNB (mint emulated by transferring from this mock's pre-funded balance).
  function deposit() external payable {
    uint256 out = (msg.value * 1e18) / rate;
    IERC20(slisBnb).transfer(msg.sender, out);
  }

  /// @notice Real-time redeem slisBNB → BNB at the on-chain rate. Matches IStakeManager (returns BNB out).
  function instantWithdraw(uint256 amount) external returns (uint256 bnbAmount) {
    IERC20(slisBnb).transferFrom(msg.sender, address(this), amount);
    bnbAmount = (amount * rate) / 1e18;
    (bool ok, ) = msg.sender.call{ value: bnbAmount }("");
    require(ok, "bnb send failed");
  }

  receive() external payable {}
}

/// @notice Rate-path integration tests for the slisBNB/BNB V3 LP topology (3-contract split:
///         SlisBNBV3DexAdapter + SlisBNBV3Provider vault + SlisBNBV3ProviderOracle), forked against the
///         live PancakeSwap V3 slisBNB/WBNB 1bp pool + the real slisBNB StakeManager. Verifies the
///         exchange-rate oracle (providerOracle.peek / vault.totalAssets / vault.getUserBalanceInBnb) is
///         invariant to pool-price manipulation, and that the custom slisBNB/BNB rebalance entry point
///         (vault → adapter) runs end-to-end.
///
/// @dev Pancake-stand-in caveats handled by this harness (the production target is a real Lista V3
///      slisBNB/BNB pool): (1) the adapter reads slot0 via {IV3PoolMinimal} so Pancake's uint32
///      `feeProtocol` packing doesn't break the uint8-typed full-tuple decode; (2) the {PoolSwapper}
///      implements `pancakeV3SwapCallback`; (3) a {MockStakeManager} is etched at the StakeManager
///      address because the live impl at this block predates `instantWithdraw`.
contract SlisBNBV3ProviderRateTest is Test {
  using MarketParamsLib for MarketParams;

  /* live slisBNB/WBNB 1bp PancakeSwap V3 pool (stand-in for the not-yet-created Lista V3 pool) */
  address constant POOL = 0xe1B404Aaf60eEc5c8A1FEDE7dcDC0EAb9C69662F;
  address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364; // canonical Pancake V3 NPM (factory 0x0BFbCF)
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
  uint256 constant LLTV = 70 * 1e16;
  uint256 constant BNB_USD = 600e8; // mock BNB price, 8 decimals

  Moolah moolah;
  SlisBNBV3DexAdapter adapter;
  SlisBNBV3Provider provider;
  SlisBNBV3ProviderOracle providerOracle;
  MockOracle oracle;
  PoolSwapper swapper;
  MarketParams marketParams;
  Id marketId;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);
    emit log_named_uint("gas_at_start", gasleft());

    // Upgrade Moolah to the local implementation (the deployed impl at this block predates the
    // current setProvider/provider wiring used by the split topology).
    address newMoolahImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newMoolahImpl, bytes(""));

    // Mock resilient oracle: WBNB = BNB price; slisBNB = BNB price × exchange rate (OracleAdaptor-style).
    oracle = new MockOracle();
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, (BNB_USD * rate) / 1e18);

    // Etch a faithful StakeManager stand-in (same rate) so `instantWithdraw` — absent on the live
    // impl at this block — exists for the rebalance inventory conversion. Fund it on both legs.
    MockStakeManager mockSm = new MockStakeManager(rate, SLISBNB);
    vm.etch(STAKE_MANAGER, address(mockSm).code);
    vm.deal(STAKE_MANAGER, 1_000_000 ether);
    deal(SLISBNB, STAKE_MANAGER, 1_000_000 ether);

    // Deploy the (large) topology contracts FIRST, while setUp gas is untouched — forge's setUp gas
    // forwarding chokes on the big code deposits if other deploys run before them. Order: adapter,
    // then vault (depends on adapter), then oracle (depends on adapter + vault).

    // 1) DEX adapter (NFT custodian + rate/rebalance logic).
    SlisBNBV3DexAdapter adapterImpl = new SlisBNBV3DexAdapter(NPM, SLISBNB, WBNB, FEE, TWAP_PERIOD);
    adapter = SlisBNBV3DexAdapter(
      payable(new ERC1967Proxy(address(adapterImpl), abi.encodeCall(SlisBNBV3DexAdapter.initialize, (admin, manager))))
    );

    // 2) Vault (ERC-4626 shares + Moolah wiring). accountingAsset = WBNB for these pools.
    SlisBNBV3Provider provImpl = new SlisBNBV3Provider(MOOLAH_PROXY, address(adapter));
    provider = SlisBNBV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            SlisBNBV3Provider.initialize,
            (admin, manager, bot, address(oracle), WBNB, "slisBNB/BNB vLP", "vLP-slisBNB-BNB")
          )
        )
      )
    );

    // 3) Wire adapter -> vault (one-time, admin).
    vm.prank(admin);
    adapter.setProvider(address(provider));

    // 4) Oracle (Moolah market.oracle; prices the share off the adapter's fair view).
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

    moolah = Moolah(MOOLAH_PROXY);

    swapper = new PoolSwapper();
    emit log_named_uint("gas_after_swapper", gasleft());

    assertEq(adapter.lastCenterRate(), rate, "lastCenterRate initialized from StakeManager");
    assertEq(adapter.centerRateThresholdBps(), 100, "default center-rate threshold is 1%");
    assertEq(provider.asset(), WBNB, "accounting asset");
    assertEq(provider.accountingAssetDecimals(), 18, "accounting asset decimals");

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

  function _deposit(uint256 amtSlis, uint256 amtWbnb) internal returns (uint256 shares) {
    deal(SLISBNB, user, amtSlis);
    deal(WBNB, user, amtWbnb);
    (, uint256 e0, uint256 e1) = provider.previewDepositAmounts(amtSlis, amtWbnb);
    vm.startPrank(user);
    IERC20(SLISBNB).approve(address(provider), amtSlis);
    IERC20(WBNB).approve(address(provider), amtWbnb);
    (shares, , ) = provider.deposit(marketParams, amtSlis, amtWbnb, (e0 * 99) / 100, (e1 * 99) / 100, user);
    vm.stopPrank();
  }

  /// @dev Big WBNB->slisBNB swap to push pool price far, then warp time (so a TWAP would also move).
  function _manipulatePoolUp(uint256 amountIn) internal {
    deal(WBNB, address(swapper), amountIn);
    swapper.swapExactIn(POOL, false, amountIn); // token1 (WBNB) in → price up
    vm.warp(block.timestamp + 3600);
  }

  /* ─────────────────── exchange-rate oracle: invariance ─────────────────── */

  function test_peek_usesRate_invariantToPoolManipulation() public {
    _deposit(10 ether, 10 ether);

    uint256 peekBefore = providerOracle.peek(address(provider));
    (uint256 s0Before, uint256 s1Before) = provider.getTotalAmounts(); // slot0-based, for contrast

    int24 tickBefore = _tick();
    _manipulatePoolUp(20_000 ether);
    int24 tickAfter = _tick();

    uint256 peekAfter = providerOracle.peek(address(provider));
    (uint256 s0After, uint256 s1After) = provider.getTotalAmounts();

    // sanity: the pool price actually moved a lot
    assertGt(tickAfter - tickBefore, 100, "pool tick should move materially");
    // contrast: the slot0-based composition shifted materially...
    assertTrue(s0After != s0Before || s1After != s1Before, "slot0 composition should shift");
    // ...but the rate-based collateral price is invariant (only tiny fee accrual on our position).
    assertApproxEqRel(peekAfter, peekBefore, 1e16, "peek must be invariant to pool price (<=1%)");
    assertGt(peekBefore, 0, "peek should be non-zero");
  }

  function test_getUserBalanceInBnb_invariantToPoolManipulation() public {
    _deposit(10 ether, 10 ether);
    provider.syncUserBalance(marketId, user); // record deposit tracking

    uint256 bnbBefore = provider.getUserBalanceInBnb(user);
    _manipulatePoolUp(20_000 ether);
    uint256 bnbAfter = provider.getUserBalanceInBnb(user);

    assertGt(bnbBefore, 0, "should have a BNB-denominated balance");
    assertApproxEqRel(bnbAfter, bnbBefore, 1e16, "getUserBalanceInBnb must track rate, not pool");
  }

  function test_totalAssets_invariantToPoolManipulation() public {
    _deposit(10 ether, 10 ether);

    uint256 taBefore = provider.totalAssets();
    _manipulatePoolUp(20_000 ether);
    uint256 taAfter = provider.totalAssets();

    assertGt(taBefore, 0, "totalAssets should be non-zero");
    assertApproxEqRel(taAfter, taBefore, 1e16, "totalAssets (WBNB) must track rate, not pool");
  }

  function test_peek_doesNotRevert_withoutTwapHistory() public {
    // The pool has observationCardinality == 1, so the base TWAP path would revert on observe().
    // The rate path must not depend on it.
    _deposit(10 ether, 10 ether);
    uint256 p = providerOracle.peek(address(provider));
    assertGt(p, 0, "rate-based peek works even without TWAP history");
  }

  /* ───────────────────── custom slisBNB/BNB rebalance ───────────────────── */

  function test_rebalance_recentersToRateDerivedRange() public {
    _deposit(10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, block.timestamp);

    assertGt(adapter.tokenId(), oldTokenId, "position should be re-minted");
    assertLt(adapter.tickLower(), adapter.tickUpper(), "rate-derived range should be valid");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "rebalance is ~value-neutral");
    assertEq(adapter.lastCenterRate(), IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18), "center rate updated");
  }

  function test_rebalance_revertsWhenCenterRateDeviationBelowThreshold() public {
    _deposit(10 ether, 10 ether);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.RateDeviationBelowThreshold.selector);
    provider.rebalance(0, 0, 0, block.timestamp);
  }

  function test_rebalance_revertsAfterDeadline() public {
    _deposit(10 ether, 10 ether);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.DeadlineExpired.selector);
    provider.rebalance(0, 0, 0, block.timestamp - 1);
  }

  function test_rebalance_revertsWhenMinLiquidityTooHigh() public {
    _deposit(10 ether, 10 ether);

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.InsufficientLiquidityMinted.selector);
    provider.rebalance(0, 0, type(uint256).max, block.timestamp);
  }

  function _tick() internal view returns (int24 tick) {
    (, tick) = IV3PoolMinimal(POOL).slot0();
  }
}

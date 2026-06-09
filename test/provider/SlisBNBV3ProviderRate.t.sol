// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SlisBNBV3Provider } from "../../src/provider/SlisBNBV3Provider.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";
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

/// @dev Executes a direct pool swap and satisfies the PancakeSwap V3 callback (to manipulate price).
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

/// @notice Rate-path integration tests for SlisBNBV3Provider, forked against the live
///         PancakeSwap V3 slisBNB/WBNB 1bp pool + the real slisBNB StakeManager. Verifies the
///         exchange-rate oracle (peek / totalAssets / getUserBalanceInBnb) is invariant to pool-price
///         manipulation, and that the custom slisBNB/BNB rebalance entry point runs end-to-end.
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
  SlisBNBV3Provider provider;
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

    // Deploy the (large) provider implementation FIRST, while setUp gas is untouched — forge's setUp
    // gas forwarding chokes on the ~5.3M code-deposit if other deploys run before it.
    SlisBNBV3Provider impl = new SlisBNBV3Provider(MOOLAH_PROXY, NPM, SLISBNB, WBNB, FEE, TWAP_PERIOD);

    moolah = Moolah(MOOLAH_PROXY);

    // Mock resilient oracle: WBNB = BNB price; slisBNB = BNB price × exchange rate (OracleAdaptor-style).
    oracle = new MockOracle();
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, (BNB_USD * rate) / 1e18);

    swapper = new PoolSwapper();
    emit log_named_uint("gas_after_swapper", gasleft());

    bytes memory initData = abi.encodeCall(
      SlisBNBV3Provider.initialize,
      (admin, manager, bot, address(oracle), "slisBNB/BNB vLP", "vLP-slisBNB-BNB")
    );
    provider = SlisBNBV3Provider(payable(new ERC1967Proxy(address(impl), initData)));
    assertEq(provider.lastCenterRate(), rate, "lastCenterRate initialized from StakeManager");
    assertEq(provider.centerRateThresholdBps(), 100, "default center-rate threshold is 1%");

    marketParams = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(provider),
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

    uint256 peekBefore = provider.peek(address(provider));
    (uint256 s0Before, uint256 s1Before) = provider.getTotalAmounts(); // slot0-based, for contrast

    int24 tickBefore = _tick();
    _manipulatePoolUp(20_000 ether);
    int24 tickAfter = _tick();

    uint256 peekAfter = provider.peek(address(provider));
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
    uint256 p = provider.peek(address(provider));
    assertGt(p, 0, "rate-based peek works even without TWAP history");
  }

  /* ───────────────────── custom slisBNB/BNB rebalance ───────────────────── */

  function test_rebalance_recentersToRateDerivedRange() public {
    _deposit(10 ether, 10 ether);
    uint256 peekBefore = provider.peek(address(provider));
    uint256 oldTokenId = provider.tokenId();

    vm.prank(manager);
    provider.setCenterRateThresholdBps(0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, block.timestamp);

    assertGt(provider.tokenId(), oldTokenId, "position should be re-minted");
    assertLt(provider.tickLower(), provider.tickUpper(), "rate-derived range should be valid");
    assertApproxEqRel(provider.peek(address(provider)), peekBefore, 2e16, "rebalance is ~value-neutral");
    assertEq(provider.lastCenterRate(), IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18), "center rate updated");
  }

  function test_rebalance_revertsWhenCenterRateDeviationBelowThreshold() public {
    _deposit(10 ether, 10 ether);

    vm.prank(bot);
    vm.expectRevert(SlisBNBV3Provider.RateDeviationBelowThreshold.selector);
    provider.rebalance(0, 0, 0, block.timestamp);
  }

  function test_rebalance_revertsAfterDeadline() public {
    _deposit(10 ether, 10 ether);

    vm.prank(bot);
    vm.expectRevert(SlisBNBV3Provider.DeadlineExpired.selector);
    provider.rebalance(0, 0, 0, block.timestamp - 1);
  }

  function test_rebalance_revertsWhenMinLiquidityTooHigh() public {
    _deposit(10 ether, 10 ether);

    vm.prank(manager);
    provider.setCenterRateThresholdBps(0);

    vm.prank(bot);
    vm.expectRevert(SlisBNBV3Provider.InsufficientLiquidityMinted.selector);
    provider.rebalance(0, 0, type(uint256).max, block.timestamp);
  }

  function _tick() internal view returns (int24 tick) {
    (, tick, , , , , ) = IListaV3Pool(POOL).slot0();
  }
}

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
import { SwapInventoryLib } from "../../src/provider/libraries/SwapInventoryLib.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IV3PoolMinimal } from "../../src/provider/interfaces/IV3PoolMinimal.sol";
import { INonfungiblePositionManager } from "../../src/provider/interfaces/INonfungiblePositionManager.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { TokenConfig, IOracle } from "moolah/interfaces/IOracle.sol";
import { SlisBNBxMinter, ISlisBNBx } from "../../src/utils/SlisBNBxMinter.sol";

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
    IListaV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(pool));
  }

  /// @dev V3 swap callback — pay whatever the pool pulled. PancakeSwap pools call the `pancake…`
  ///      name, Uniswap pools the `uniswap…` name; support both.
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

/// @dev Minimal DEX-agnostic swap venue the rebalance backend routes through (the slisBNB conversion is
///      now a backend-built swap, not a StakeManager special case): pulls `amountIn` of tokenIn from the
///      caller (the adapter, which forceApproved it) and sends a fixed `amountOut` of tokenOut to `to`.
contract MockSwap {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    IERC20(tokenOut).transfer(to, amountOut);
  }
}

/// @dev A venue that pulls an ERC-20 input but (incorrectly) pays the output in the NATIVE coin — used to
///      prove the adapter wraps stray native (never strands it) and then reverts on the missing ERC-20 out.
contract NativeSwap {
  function swap(address tokenIn, uint256 amountIn, uint256 nativeOut, address to) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    (bool ok, ) = to.call{ value: nativeOut }("");
    require(ok, "native send failed");
  }

  receive() external payable {}
}

/// @notice Functional integration tests for the slisBNB/BNB V3 LP topology (3-contract split:
///         SlisBNBV3DexAdapter + SlisBNBV3Provider vault + SlisBNBV3ProviderOracle), forked against the
///         live PancakeSwap V3 slisBNB/WBNB 1bp pool + a faithful slisBNB StakeManager stand-in.
contract SlisBNBV3ProviderTest is Test {
  using MarketParamsLib for MarketParams;
  using stdStorage for StdStorage;

  /* ─────────────────── PancakeSwap V3 slisBNB/WBNB 1bp ─────────────────── */
  address constant POOL = 0xe1B404Aaf60eEc5c8A1FEDE7dcDC0EAb9C69662F; // slisBNB/WBNB
  address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
  uint24 constant FEE = 100;

  /* ───────────────────────────── tokens ───────────────────────────── */
  address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // token0
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // token1
  address constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /* ──────────────────────── Moolah ecosystem ──────────────────────── */
  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint32 constant TWAP_PERIOD = 1800; // 30 minutes
  uint256 constant LLTV = 70 * 1e16;
  uint256 constant LLTV_SECOND = 71 * 1e16;
  uint256 constant BNB_USD = 600e8; // mock BNB price, 8 decimals

  /* ───────────────────────── test contracts ───────────────────────── */
  Moolah moolah;
  SlisBNBV3Provider provider;
  SlisBNBV3DexAdapter adapter;
  SlisBNBV3ProviderOracle providerOracle;
  MockOracle oracle;
  MockSwap mockSwap;
  MarketParams marketParams;
  Id marketId;

  /// @dev slisBNB USD price (= BNB_USD × StakeManager rate); WBNB priced at BNB_USD. Both set in setUp.
  uint256 slisPrice;
  uint256 constant wbnbPrice = BNB_USD;

  /* ───────────────────────── test accounts ────────────────────────── */
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  /* ────────────────────────────── setUp ───────────────────────────── */

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    // Read the live exchange rate BEFORE etching the StakeManager mock.
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);

    // Mock resilient oracle: WBNB = BNB price; slisBNB = BNB price × exchange rate (OracleAdaptor-style).
    oracle = new MockOracle();
    slisPrice = (BNB_USD * rate) / 1e18;
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, slisPrice);
    oracle.setPrice(LISUSD, 1e8); // lisUSD ≈ $1 — needed for Moolah's loan-token health check / borrow math

    // Etch a faithful StakeManager stand-in (same rate) so `instantWithdraw` — absent on the live
    // impl at this block — exists for the rebalance inventory conversion. Fund it on both legs.
    MockStakeManager mockSm = new MockStakeManager(rate, SLISBNB);
    vm.etch(STAKE_MANAGER, address(mockSm).code);
    vm.deal(STAKE_MANAGER, 1_000_000 ether);
    deal(SLISBNB, STAKE_MANAGER, 1_000_000 ether);

    // Deploy the heavy contracts (adapter → provider → oracle) EARLY in setUp,
    // before unrelated deploys, to avoid forge setUp gas-forwarding issues with
    // large code deposits.

    // 1) DEX adapter (NFT custodian + all NPM/pool interaction).
    SlisBNBV3DexAdapter adapterImpl = new SlisBNBV3DexAdapter(NPM, SLISBNB, WBNB, FEE, TWAP_PERIOD);
    adapter = SlisBNBV3DexAdapter(
      payable(new ERC1967Proxy(address(adapterImpl), abi.encodeCall(SlisBNBV3DexAdapter.initialize, (admin, manager))))
    );

    // 2) Provider / vault (ERC-4626 vLP shares + Moolah wiring). accountingAsset = WBNB.
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

    // 3) Wire adapter → provider (one-time, admin).
    vm.prank(admin);
    adapter.setProvider(address(provider));

    // DEX-agnostic swap venue stand-in: whitelist it so backend-built rebalance swapData may target it.
    mockSwap = new MockSwap();
    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(mockSwap), true);

    // 4) Share oracle (Moolah market.oracle points here).
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

    // Upgrade Moolah to the latest local implementation.
    address newImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Build Moolah market: collateral = provider shares, oracle = providerOracle.
    marketParams = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    marketId = marketParams.id();

    // Create market and register SlisBNBV3Provider as the Moolah provider.
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
    deal(SLISBNB, _user, amount0);
    deal(WBNB, _user, amount1);
    // Derive tight min amounts (0.1% slippage) from previewDeposit so that we
    // never bypass the slippage guard with zeros.
    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(amount0, amount1);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;
    vm.startPrank(_user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(marketParams, amount0, amount1, min0, min1, 0, _user);
    vm.stopPrank();
  }

  function _collateral(address _user) internal view returns (uint256) {
    (, , uint256 col) = moolah.position(marketId, _user);
    return col;
  }

  function _createSecondMarket() internal returns (MarketParams memory secondParams, Id secondId) {
    secondParams = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV_SECOND
    });
    secondId = secondParams.id();

    if (!moolah.isLltvEnabled(LLTV_SECOND)) {
      vm.prank(MANAGER_ADDR);
      moolah.enableLltv(LLTV_SECOND);
    }

    vm.prank(OPERATOR);
    moolah.createMarket(secondParams);

    vm.prank(MANAGER_ADDR);
    moolah.setProvider(secondId, address(provider), true);
  }

  /* ────────────────────────── test cases ─────────────────────────── */

  function test_initialize() public view {
    assertEq(provider.TOKEN0(), SLISBNB);
    assertEq(provider.TOKEN1(), WBNB);
    assertEq(adapter.FEE(), FEE);
    assertEq(adapter.POOL(), POOL);
    assertEq(address(provider.MOOLAH()), MOOLAH_PROXY);
    assertEq(address(adapter.POSITION_MANAGER()), NPM);
    assertEq(provider.resilientOracle(), address(oracle));
    assertEq(provider.asset(), WBNB);
    assertEq(provider.accountingAssetDecimals(), 18);
    assertEq(adapter.TWAP_PERIOD(), TWAP_PERIOD);
    assertLt(adapter.tickLower(), adapter.tickUpper());
    assertTrue(provider.hasRole(provider.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(provider.hasRole(provider.MANAGER(), manager));
    assertTrue(provider.hasRole(provider.BOT(), bot));
    // BOT role admin is MANAGER
    assertEq(provider.getRoleAdmin(provider.BOT()), provider.MANAGER());
    // adapter is wired to the provider/vault
    assertEq(adapter.provider(), address(provider));
  }

  function test_deposit_firstDeposit() public {
    uint256 amount0 = 10 ether; // slisBNB
    uint256 amount1 = 10 ether; // WBNB

    (uint256 shares, uint256 used0, uint256 used1) = _deposit(user, amount0, amount1);

    assertGt(shares, 0, "should mint shares");
    assertGt(used0 + used1, 0, "should consume tokens");

    // Collateral position in Moolah equals shares minted.
    assertEq(_collateral(user), shares, "Moolah collateral should equal shares");

    // Shares are held by Moolah, not user.
    assertEq(provider.balanceOf(user), 0, "user should hold no shares directly");
    assertEq(provider.balanceOf(MOOLAH_PROXY), shares, "Moolah should hold shares");

    // Unused tokens refunded to caller.
    // slisBNB refunded as ERC-20; WBNB (TOKEN1 = WRAPPED_NATIVE) refunded as native BNB.
    assertEq(IERC20(SLISBNB).balanceOf(user), amount0 - used0);
    assertEq(user.balance, amount1 - used1);
  }

  function test_deposit_secondDeposit_doesNotDilute() public {
    // Shares are issued proportional to the fair composition (value-conserving), not to raw
    // token inputs — the first deposit refunds part of its WBNB at the spot mint ratio, so equal token
    // amounts are not equal value. The invariant that matters is that the mint never lowers the existing
    // per-share price, and a larger-value deposit yields more shares.
    (uint256 shares1, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 priceBefore = providerOracle.peek(address(provider));

    (uint256 shares2, , ) = _deposit(user2, 20 ether, 20 ether);
    uint256 priceAfter = providerOracle.peek(address(provider));

    assertGe(priceAfter, priceBefore, "second deposit must not dilute existing share price");
    assertGt(shares2, shares1, "larger-value deposit yields more shares");
  }

  /// @dev H02 / Issue_04 (+ M01) counter-test. The minShares floor makes a deposit revert instead of
  ///      silently under-crediting the depositor when it would receive fewer shares than demanded — the
  ///      protection against a first-depositor inflation attack (a direct NPM.increaseLiquidity donation
  ///      inflates the composition so a normal deposit rounds down) and against the fair composition
  ///      drifting between the off-chain preview and execution. A minShares at fair passes; a higher one
  ///      reverts.
  function test_deposit_minShares_guardsShareSlippage() public {
    _deposit(user, 10 ether, 10 ether);

    // Preview the shares a balanced 10/10 deposit would mint at the current fair composition.
    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(10 ether, 10 ether);
    uint256 supplyBefore = provider.totalSupply();
    (uint256 t0, uint256 t1) = provider.getFairComposition();
    uint256 fracExp = (exp0 * 1e18) / t0 < (exp1 * 1e18) / t1 ? (exp0 * 1e18) / t0 : (exp1 * 1e18) / t1;
    uint256 expectedShares = (supplyBefore * fracExp) / 1e18;

    deal(SLISBNB, user2, 10 ether);
    deal(WBNB, user2, 10 ether);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), 10 ether);
    IERC20(WBNB).approve(address(provider), 10 ether);

    // Demanding more than the deposit can mint reverts (does not silently under-credit).
    vm.expectRevert(V3Provider.InsufficientShares.selector);
    provider.deposit(marketParams, 10 ether, 10 ether, 0, 0, expectedShares * 2, user2);

    // A floor at/just below the achievable amount passes.
    (uint256 shares, , ) = provider.deposit(marketParams, 10 ether, 10 ether, 0, 0, (expectedShares * 99) / 100, user2);
    vm.stopPrank();
    assertGe(shares, (expectedShares * 99) / 100, "mint met the minShares floor");
  }

  function test_withdraw_fullWithdrawal() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    uint256 slisBefore = IERC20(SLISBNB).balanceOf(user);
    uint256 bnbBefore = user.balance; // WBNB (TOKEN1) is unwrapped to native BNB on withdrawal

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, min0, min1, user, user);

    // Collateral cleared.
    assertEq(_collateral(user), 0, "collateral should be zero after full withdrawal");

    // Tokens returned.
    assertGt(out0 + out1, 0, "should receive tokens back");
    assertEq(IERC20(SLISBNB).balanceOf(user), slisBefore + out0);
    assertEq(user.balance, bnbBefore + out1); // WBNB unwrapped to BNB
  }

  function test_withdraw_partialWithdrawal() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares / 2);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(user);
    provider.withdraw(marketParams, shares / 2, min0, min1, user, user);

    assertApproxEqAbs(_collateral(user), shares / 2, 1, "half collateral should remain");
  }

  function test_withdraw_revertsIfUnauthorized() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 shares = _collateral(user);

    // user2 cannot withdraw on behalf of user without authorization.
    // The revert fires on the auth check before min amounts are evaluated; use 1,1.
    vm.prank(user2);
    vm.expectRevert(V3Provider.Unauthorized.selector);
    provider.withdraw(marketParams, shares, 1, 1, user, user2);
  }

  function test_withdrawShares_toWallet_doesNotRedeemUnderlying() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 supplyBefore = provider.totalSupply();
    uint256 tokenIdBefore = adapter.tokenId();

    vm.prank(user);
    provider.withdrawShares(marketParams, shares, user, user);

    assertEq(_collateral(user), 0, "collateral should be withdrawn from market");
    assertEq(provider.balanceOf(user), shares, "user should hold vLP shares");
    assertEq(provider.balanceOf(MOOLAH_PROXY), 0, "Moolah should hold no shares");
    assertEq(provider.totalSupply(), supplyBefore, "shares should not be burned");
    assertEq(adapter.tokenId(), tokenIdBefore, "V3 position should remain intact");
    assertEq(provider.userMarketDeposit(user, marketId), 0, "market tracking should clear");
    assertEq(provider.userTotalDeposit(user), 0, "total tracking should clear");
  }

  function test_withdrawShares_revertsIfUnauthorized() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 shares = _collateral(user);

    vm.prank(user2);
    vm.expectRevert(V3Provider.Unauthorized.selector);
    provider.withdrawShares(marketParams, shares, user, user2);
  }

  function test_supplyShares_fromWallet_suppliesCollateral() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    vm.startPrank(user);
    provider.withdrawShares(marketParams, shares, user, user);
    provider.supplyShares(marketParams, shares, user);
    vm.stopPrank();

    assertEq(_collateral(user), shares, "collateral should be restored");
    assertEq(provider.balanceOf(user), 0, "user should no longer hold shares");
    assertEq(provider.balanceOf(MOOLAH_PROXY), shares, "Moolah should hold shares");
    assertEq(provider.userMarketDeposit(user, marketId), shares, "market tracking should restore");
    assertEq(provider.userTotalDeposit(user), shares, "total tracking should restore");
  }

  function test_supplyShares_revertsIfSenderDoesNotHoldShares() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    vm.prank(user2);
    vm.expectRevert(V3Provider.InsufficientShares.selector);
    provider.supplyShares(marketParams, shares, user2);
  }

  function test_withdrawShares_supplyShares_movesCollateralBetweenMarkets() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    (MarketParams memory secondParams, Id secondId) = _createSecondMarket();

    vm.startPrank(user);
    provider.withdrawShares(marketParams, shares, user, user);
    provider.supplyShares(secondParams, shares, user);
    vm.stopPrank();

    (, , uint256 secondCollateral) = moolah.position(secondId, user);
    assertEq(_collateral(user), 0, "first market collateral should be empty");
    assertEq(secondCollateral, shares, "second market collateral should receive shares");
    assertEq(provider.balanceOf(user), 0, "wallet should not retain shares");
    assertEq(provider.balanceOf(MOOLAH_PROXY), shares, "Moolah should custody shares");
    assertEq(provider.userMarketDeposit(user, marketId), 0, "first market tracking should clear");
    assertEq(provider.userMarketDeposit(user, secondId), shares, "second market tracking should update");
    assertEq(provider.userTotalDeposit(user), shares, "total tracking should remain one deposit");
  }

  function test_redeemShares_byLiquidator() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    address liquidator = makeAddr("liquidator");

    // Simulate Moolah transferring shares to liquidator during liquidation.
    // (transfer is restricted to Moolah — prank as Moolah to move shares)
    vm.prank(MOOLAH_PROXY);
    provider.transfer(liquidator, shares);

    assertEq(provider.balanceOf(liquidator), shares);

    uint256 slisBefore = IERC20(SLISBNB).balanceOf(liquidator);
    uint256 bnbBefore = liquidator.balance; // WBNB (TOKEN1) is unwrapped to native BNB

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;

    vm.prank(liquidator);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, min0, min1, liquidator);

    assertEq(provider.balanceOf(liquidator), 0, "shares should be burned");
    assertGt(out0 + out1, 0, "liquidator should receive tokens");
    assertEq(IERC20(SLISBNB).balanceOf(liquidator), slisBefore + out0);
    assertEq(liquidator.balance, bnbBefore + out1); // WBNB unwrapped to BNB
  }

  function test_transferRestriction_directTransferReverts() public {
    _deposit(user, 10 ether, 10 ether);

    vm.prank(user);
    vm.expectRevert(V3Provider.OnlyMoolah.selector);
    provider.transfer(user2, 1);
  }

  function test_transferRestriction_transferFromReverts() public {
    _deposit(user, 10 ether, 10 ether);

    vm.prank(user);
    vm.expectRevert(V3Provider.OnlyMoolah.selector);
    provider.transferFrom(MOOLAH_PROXY, user2, 1);
  }

  /// @dev Even Moolah's own transferFrom must debit the allowance the owner granted it, rather than
  ///      moving shares with an unbounded allowance. No allowance ⇒ revert; a set allowance is spent.
  function test_transferRestriction_moolahTransferFromSpendsAllowance() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    // The deposit path parked the shares in Moolah as collateral; move them back to `user` to hold.
    vm.prank(user);
    provider.withdrawShares(marketParams, shares, user, user);

    // Moolah with no allowance from `user` cannot pull shares.
    vm.prank(MOOLAH_PROXY);
    vm.expectRevert();
    provider.transferFrom(user, user2, shares);

    // With an allowance set, Moolah's transferFrom succeeds and the allowance is debited.
    vm.prank(user);
    provider.approve(MOOLAH_PROXY, shares);
    vm.prank(MOOLAH_PROXY);
    provider.transferFrom(user, user2, shares);

    assertEq(provider.balanceOf(user2), shares, "shares moved to user2");
    assertEq(provider.allowance(user, MOOLAH_PROXY), 0, "allowance fully spent");
  }

  function test_rebalance_onlyBot() public {
    _deposit(user, 10 ether, 10 ether);

    // manager cannot rebalance — revert fires on role check before amounts matter.
    vm.prank(manager);
    vm.expectRevert();
    provider.rebalance(1, 1, 1, 0, block.timestamp, "");

    // Disable the rate-drift guard — a pool swap does NOT move the StakeManager rate, so the
    // default 1% center-rate threshold would block this rebalance with RateDeviationBelowThreshold.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // bot can rebalance — range is derived internally by the provider/adapter.
    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    uint256 min0 = (total0 * 999) / 1000;
    uint256 min1 = (total1 * 999) / 1000;
    uint256 oldTokenId = adapter.tokenId();
    vm.prank(bot);
    provider.rebalance(min0, min1, 0, 0, block.timestamp, "");

    assertGt(adapter.tokenId(), oldTokenId, "position NFT should be re-minted");
    assertLt(adapter.tickLower(), adapter.tickUpper());
  }

  function test_rebalance_liquidity_preserved() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();

    // Disable the rate-drift guard (the rate is unchanged by deposits / pool activity).
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    uint256 min0 = (total0 * 999) / 1000;
    uint256 min1 = (total1 * 999) / 1000;
    vm.prank(bot);
    provider.rebalance(min0, min1, 0, 0, block.timestamp, "");

    // Share count is unchanged after rebalance.
    assertEq(_collateral(user), shares, "shares should be unchanged after rebalance");

    // Total amounts should be roughly preserved (small dust from ratio mismatch is acceptable).
    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueBefore = total0Before + total1Before;
    uint256 valueAfter = total0After + total1After;
    assertApproxEqRel(valueAfter, valueBefore, 0.02e18, "total value should be preserved within 2%");
  }

  function test_peek_zeroBeforeDeposit() public view {
    assertEq(providerOracle.peek(address(provider)), 0, "price should be 0 with no deposits");
  }

  function test_peek_nonZeroAfterDeposit() public {
    _deposit(user, 10 ether, 10 ether);

    uint256 price = providerOracle.peek(address(provider));
    assertGt(price, 0, "share price should be non-zero after deposit");
  }

  function test_getTotalAmounts_nonZeroAfterDeposit() public {
    _deposit(user, 10 ether, 10 ether);

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertGt(total0 + total1, 0, "total amounts should be non-zero after deposit");
  }

  function test_compoundFees_shareValueIncreasesOverTime() public {
    // slisBNB pricing uses the StakeManager rate (set on the MockOracle in setUp), not pool TWAP,
    // so no RESILIENT_ORACLE price mocks and no pool.observe() mock are needed across the warp.
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    uint256 priceBefore = providerOracle.peek(address(provider));

    // Simulate time passing and swap activity accumulating fees by warping forward.
    vm.warp(block.timestamp + 7 days);

    // A second deposit triggers _collectAndCompound internally.
    _deposit(user2, 10 ether, 10 ether);

    uint256 priceAfter = providerOracle.peek(address(provider));

    // Share price should be >= before (fees compounded, no value destroyed).
    assertGe(priceAfter, priceBefore, "share price should not decrease after compounding");

    // user's collateral share count is unchanged.
    assertEq(_collateral(user), shares);
  }

  /// @dev Counter-test (deposit cannot be gamed via spot vs idle). With tracked idle inventory present AND the pool spot pushed far from
  ///      the fair (rate) price, the OLD deposit path minted liquidity at spot but valued it at fair,
  ///      over-crediting the new depositor and dropping existing holders' share price (dilution/theft).
  ///      The deposit is proportional to the fair composition and parks to idle — the pool spot
  ///      never enters share issuance — so a deposit under these exact conditions cannot dilute.
  function test_deposit_withIdleAndSkewedSpot_doesNotDilute() public {
    _deposit(user, 10 ether, 10 ether);

    // Heavy one-sided idle skews the composition (the ingredient the old bug needed)...
    uint256 idle0 = 1 ether;
    uint256 idle1 = 50 ether;
    deal(SLISBNB, address(adapter), IERC20(SLISBNB).balanceOf(address(adapter)) + idle0);
    deal(WBNB, address(adapter), IERC20(WBNB).balanceOf(address(adapter)) + idle1);
    stdstore.target(address(adapter)).sig("idleToken0()").checked_write(adapter.idleToken0() + idle0);
    stdstore.target(address(adapter)).sig("idleToken1()").checked_write(adapter.idleToken1() + idle1);
    assertGt(_valueUSD(adapter.idleToken0(), adapter.idleToken1()), 0, "test setup should include idle");

    // ...and the pool spot is pushed far above fair (the other ingredient).
    _skewSpotUp();

    uint256 priceBefore = providerOracle.peek(address(provider));
    (uint256 shares2, , ) = _deposit(user2, 10 ether, 10 ether);
    uint256 priceAfter = providerOracle.peek(address(provider));

    assertGt(shares2, 0, "deposit should still mint shares");
    assertGe(priceAfter, priceBefore, "deposit with idle + skewed spot must not dilute existing holders");
  }

  /// @dev Helper: deposit with explicit min amounts (bypasses _deposit which passes zeros).
  function _depositWithMin(
    address _user,
    uint256 amount0,
    uint256 amount1,
    uint256 min0,
    uint256 min1
  ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(SLISBNB, _user, amount0);
    deal(WBNB, _user, amount1);
    vm.startPrank(_user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(marketParams, amount0, amount1, min0, min1, 0, _user);
    vm.stopPrank();
  }

  /* ──────────────── previewDeposit tests ─────────────────────────── */

  function test_previewDeposit_amountsMatchActual() public {
    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    (uint128 liquidity, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(amount0, amount1);

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
    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(amount0, amount1);

    // Apply 0.5% slippage tolerance.
    uint256 min0 = (exp0 * 995) / 1000;
    uint256 min1 = (exp1 * 995) / 1000;

    (uint256 shares, uint256 used0, uint256 used1) = _depositWithMin(user, amount0, amount1, min0, min1);

    assertGt(shares, 0, "should mint shares");
    assertGe(used0, min0, "used0 >= min0");
    assertGe(used1, min1, "used1 >= min1");
  }

  function test_previewDeposit_belowRangeSpot_usesFairCompositionBothLegs() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange(); // manipulate SPOT below range

    // preview (and deposit) bind to the FAIR composition — rate-implied for slisBNB, which stays
    // ~in-range — so both legs are consumed regardless of where the manipulable pool spot sits.
    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(10 ether, 10 ether);
    assertGt(exp0, 0, "fair composition consumes token0 regardless of spot");
    assertGt(exp1, 0, "fair composition consumes token1 regardless of spot");
  }

  function test_previewDeposit_aboveRangeSpot_usesFairCompositionBothLegs() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange(); // manipulate SPOT above range

    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(10 ether, 10 ether);
    assertGt(exp0, 0, "fair composition consumes token0 regardless of spot");
    assertGt(exp1, 0, "fair composition consumes token1 regardless of spot");
  }

  function test_previewDepositForToken_pairsLegsAtFairComposition() public {
    _deposit(user, 10 ether, 10 ether);

    (uint256 t0, uint256 t1) = provider.getFairComposition();
    assertGt(t0, 0, "fair composition token0 > 0");
    assertGt(t1, 0, "fair composition token1 > 0");

    // token0 -> matching token1 at the fair ratio.
    uint256 a0 = 5 ether;
    uint256 a1 = provider.previewDepositForToken0(a0);
    assertEq(a1, (a0 * t1) / t0, "previewDepositForToken0 = a0 * T1 / T0");

    // Reverse direction round-trips within rounding.
    assertApproxEqRel(provider.previewDepositForToken1(a1), a0, 0.0001e18, "reverse pairing round-trips");

    // Depositing the paired amounts consumes both legs ~fully (minimal refund).
    deal(SLISBNB, user2, a0);
    deal(WBNB, user2, a1);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), a0);
    IERC20(WBNB).approve(address(provider), a1);
    (uint256 shares, uint256 used0, uint256 used1) = provider.deposit(marketParams, a0, a1, 0, 0, 0, user2);
    vm.stopPrank();

    assertGt(shares, 0, "shares minted");
    assertApproxEqRel(used0, a0, 0.001e18, "token0 consumed ~fully");
    assertApproxEqRel(used1, a1, 0.001e18, "token1 consumed ~fully");
  }

  function test_previewDeposit_secondDeposit_matchesActual() public {
    // Seed an initial position so the second deposit goes through increaseLiquidity.
    _deposit(user, 10 ether, 10 ether);

    uint256 amount0 = 20 ether;
    uint256 amount1 = 20 ether;

    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(amount0, amount1);

    uint256 min0 = exp0 > 0 ? exp0 - 1 : 0;
    uint256 min1 = exp1 > 0 ? exp1 - 1 : 0;
    (, uint256 used0, uint256 used1) = _depositWithMin(user2, amount0, amount1, min0, min1);

    assertApproxEqAbs(used0, exp0, 1, "used0 should match preview within 1 wei on second deposit");
    assertApproxEqAbs(used1, exp1, 1, "used1 should match preview within 1 wei on second deposit");
  }

  /* ──────────────── previewRedeem tests ──────────────────────────── */

  function test_previewRedeem_zeroBeforeDeposit() public view {
    (uint256 amount0, uint256 amount1) = provider.previewRedeemUnderlying(1 ether);
    assertEq(amount0, 0, "should return 0 when no position exists");
    assertEq(amount1, 0, "should return 0 when no position exists");
  }

  function test_previewRedeem_matchesActualWithdraw() public {
    // Price is inside the tick range: preview predicts both tokens, withdraw returns both.
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (, int24 currentTick) = IV3PoolMinimal(POOL).slot0();
    assertGt(currentTick, adapter.tickLower(), "price should be above tickLower");
    assertLt(currentTick, adapter.tickUpper(), "price should be below tickUpper");

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
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
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    vm.prank(MOOLAH_PROXY);
    provider.transfer(user2, shares);

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);

    uint256 min0 = exp0 > 0 ? exp0 - 1 : 0;
    uint256 min1 = exp1 > 0 ? exp1 - 1 : 0;

    vm.prank(user2);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, min0, min1, user2);

    assertApproxEqAbs(out0, exp0, 1, "out0 should match preview within 1 wei");
    assertApproxEqAbs(out1, exp1, 1, "out1 should match preview within 1 wei");
  }

  function test_previewRedeem_partialShares_proportional() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 fullExp0, uint256 fullExp1) = provider.previewRedeemUnderlying(shares);
    (uint256 halfExp0, uint256 halfExp1) = provider.previewRedeemUnderlying(shares / 2);

    // Half the shares should yield approximately half the tokens.
    assertApproxEqRel(halfExp0, fullExp0 / 2, 0.001e18, "half shares ~half token0");
    assertApproxEqRel(halfExp1, fullExp1 / 2, 0.001e18, "half shares ~half token1");
  }

  function test_previewRedeem_priceBelowRange_onlyToken0() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    assertGt(exp0, 0, "should return token0 when price below range");
    assertEq(exp1, 0, "should return no token1 when price below range");
  }

  function test_previewRedeem_priceAboveRange_onlyToken1() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    assertEq(exp0, 0, "should return no token0 when price above range");
    assertGt(exp1, 0, "should return token1 when price above range");
  }

  function test_previewRedeem_derivedMinAmounts_succeed() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);

    // Apply 0.5% slippage tolerance.
    uint256 min0 = (exp0 * 995) / 1000;
    uint256 min1 = (exp1 * 995) / 1000;

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, min0, min1, user, user);

    assertGe(out0, min0, "out0 >= min0");
    assertGe(out1, min1, "out1 >= min1");
  }

  function test_deposit_minAmount0_tooHigh_reverts_firstDeposit() public {
    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    // min0 far exceeds what NPM can place — should revert from NPM slippage check.
    deal(SLISBNB, user, amount0);
    deal(WBNB, user, amount1);
    vm.startPrank(user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, amount0 * 2, 0, 0, user);
    vm.stopPrank();
  }

  function test_deposit_minAmount1_tooHigh_reverts_firstDeposit() public {
    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    deal(SLISBNB, user, amount0);
    deal(WBNB, user, amount1);
    vm.startPrank(user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, 0, amount1 * 2, 0, user);
    vm.stopPrank();
  }

  function test_deposit_minAmount0_tooHigh_reverts_secondDeposit() public {
    _deposit(user, 10 ether, 10 ether);

    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    deal(SLISBNB, user2, amount0);
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, amount0 * 2, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_minAmount1_tooHigh_reverts_secondDeposit() public {
    _deposit(user, 10 ether, 10 ether);

    uint256 amount0 = 10 ether;
    uint256 amount1 = 10 ether;

    deal(SLISBNB, user2, amount0);
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert();
    provider.deposit(marketParams, amount0, amount1, 0, amount1 * 2, 0, user2);
    vm.stopPrank();
  }

  /* ──────────── one-sided deposit tests ──────────────────────────── */

  // When the price is in-range both tokens are required to add liquidity.
  // Supplying only one token yields 0 liquidity → the deposit must revert.
  // NOTE: V3Provider.ZeroLiquidity was REMOVED in the 3-contract split. In the new
  //       topology the adapter forwards a one-sided in-range mint straight to the V3
  //       NPM/pool, which reverts with EMPTY data (the pool's own zero-amount guard)
  //       BEFORE the vault's ZeroShares check can fire. The test intent (one-sided
  //       in-range deposit must revert) is preserved; only the revert source/selector
  //       changed (bare vm.expectRevert() instead of V3Provider.ZeroLiquidity).

  function test_deposit_oneSided_token0Only_inRange_reverts() public {
    // Price is in-range: token0 alone yields 0 liquidity → pool mint reverts (no data).
    // Pass min=0 so the failure comes from the zero-liquidity mint, not an NPM slippage check.
    deal(SLISBNB, user, 10 ether);
    vm.startPrank(user);
    IERC20(SLISBNB).approve(address(provider), 10 ether);
    vm.expectRevert();
    provider.deposit(marketParams, 10 ether, 0, 0, 0, 0, user);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token1Only_inRange_reverts() public {
    // Price is in-range: token1 alone yields 0 liquidity → pool mint reverts (no data).
    deal(WBNB, user, 10 ether);
    vm.startPrank(user);
    IERC20(WBNB).approve(address(provider), 10 ether);
    vm.expectRevert();
    provider.deposit(marketParams, 0, 10 ether, 0, 0, 0, user);
    vm.stopPrank();
  }

  // When the price is outside the range only one token is valid.
  // Supplying the correct token succeeds; supplying the wrong token reverts.

  function test_deposit_oneSided_token0Only_revertsUnderProportional() public {
    // Deposits must match the FAIR composition (rate-implied for slisBNB, always ~in-range and
    // therefore two-sided). A one-sided token0-only deposit binds the composition fraction to the empty
    // token1 leg -> frac 0 -> 0 shares -> revert. (Manipulating spot out of range does not change this,
    // because the composition is measured at fair, not spot.)
    _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    uint256 amount0 = 10 ether;
    deal(SLISBNB, user2, amount0);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), amount0);
    vm.expectRevert(); // ZeroShares
    provider.deposit(marketParams, amount0, 0, 0, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token1Only_belowRange_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    // Price below range: token1 alone yields 0 liquidity → pool mint reverts (no data).
    // (See note above test_deposit_oneSided_token0Only_inRange_reverts: ZeroLiquidity removed.)
    deal(WBNB, user2, 10 ether);
    vm.startPrank(user2);
    IERC20(WBNB).approve(address(provider), 10 ether);
    vm.expectRevert();
    provider.deposit(marketParams, 0, 10 ether, 0, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token1Only_revertsUnderProportional() public {
    // Symmetric to the token0-only case: a token1-only deposit binds frac to the empty token0 leg -> 0.
    _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    uint256 amount1 = 10 ether;
    deal(WBNB, user2, amount1);
    vm.startPrank(user2);
    IERC20(WBNB).approve(address(provider), amount1);
    vm.expectRevert(); // ZeroShares
    provider.deposit(marketParams, 0, amount1, 0, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_oneSided_token0Only_aboveRange_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    // Price above range: token0 alone yields 0 liquidity → pool mint reverts (no data).
    // (See note above test_deposit_oneSided_token0Only_inRange_reverts: ZeroLiquidity removed.)
    deal(SLISBNB, user2, 10 ether);
    vm.startPrank(user2);
    IERC20(SLISBNB).approve(address(provider), 10 ether);
    vm.expectRevert();
    provider.deposit(marketParams, 10 ether, 0, 0, 0, 0, user2);
    vm.stopPrank();
  }

  function test_deposit_revertsWithInvalidCollateralToken() public {
    MarketParams memory badParams = marketParams;
    badParams.collateralToken = SLISBNB;

    deal(SLISBNB, user, 10 ether);
    deal(WBNB, user, 10 ether);
    vm.startPrank(user);
    IERC20(SLISBNB).approve(address(provider), 10 ether);
    IERC20(WBNB).approve(address(provider), 10 ether);
    vm.expectRevert(V3Provider.InvalidCollateralToken.selector);
    // The revert fires before min amounts are evaluated; use 1,1 for consistency.
    provider.deposit(badParams, 10 ether, 10 ether, 1, 1, 0, user);
    vm.stopPrank();
  }

  function test_getTokenConfig() public view {
    TokenConfig memory config = providerOracle.getTokenConfig(address(provider));
    assertEq(config.asset, address(provider));
    assertEq(config.oracles[0], address(providerOracle));
    assertTrue(config.enableFlagsForOracles[0]);
    assertEq(config.oracles[1], address(0));
    assertEq(config.oracles[2], address(0));
  }

  /* ─────────── rebalance after price leaves range (fully slisBNB) ─────── */

  /// @dev Compute USD value (8-decimal) from raw token amounts.
  ///      token0 = slisBNB (priced at slisPrice = BNB_USD × rate), token1 = WBNB (priced at BNB_USD).
  function _valueUSD(uint256 amount0, uint256 amount1) internal view returns (uint256) {
    return (amount0 * slisPrice) / 1e18 + (amount1 * wbnbPrice) / 1e18;
  }

  /// @dev Push pool price below tickLower by swapping a large amount of slisBNB → WBNB.
  ///      zeroForOne = true (token0 → token1) drives the tick downward.
  ///      When tick < tickLower the V3 position converts entirely to token0 (slisBNB).
  ///      The ±1% range is narrow; 20k slisBNB comfortably exits it.
  function _pushPriceBelowRange() internal {
    PoolSwapper swapper = new PoolSwapper();
    uint256 slisIn = 20_000 ether;
    deal(SLISBNB, address(swapper), slisIn);
    swapper.swapExactIn(POOL, true, slisIn);
  }

  function test_rebalance_priceBelowRange_positionFullyslisBNB() public {
    _deposit(user, 10 ether, 10 ether);

    // Push price below tickLower — position should convert entirely to slisBNB (token0).
    _pushPriceBelowRange();

    (, int24 tickAfterSwap) = IV3PoolMinimal(POOL).slot0();
    assertLt(tickAfterSwap, adapter.tickLower(), "tick should be below tickLower after swap");

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertGt(total0, 0, "should hold slisBNB");
    assertEq(total1, 0, "position should be fully slisBNB (token1 == 0) when price is below range");
  }

  function test_rebalance_priceBelowRange_totalValuePreserved() public {
    _deposit(user, 10 ether, 10 ether);

    _pushPriceBelowRange();

    // Snapshot USD value before rebalance (position is 100% slisBNB).
    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();
    uint256 valueBefore = _valueUSD(total0Before, total1Before);
    assertGt(valueBefore, 0, "should have non-zero value before rebalance");

    // The rate-derived recenter target is unaffected by a pool swap, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Rebalance uses an internally derived range; caller only supplies execution guards.
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");

    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueAfter = _valueUSD(total0After, total1After);

    // Recenter-only (empty swapData ⇒ no inventory conversion): the all-slisBNB inventory is re-minted
    // into the rate-derived range (excess held as idle), so total VALUE is preserved within ~2%. The
    // actual slisBNB↔WBNB conversion is exercised by the swap-venue tests below.
    assertApproxEqRel(valueAfter, valueBefore, 0.02e18, "recenter-only preserves total value within 2%");
  }

  /* ─────── rebalance inventory conversion via a whitelisted swap venue (DEX-agnostic) ─────── */

  /// @notice The rebalance converts inventory through a backend-built swap against a whitelisted venue
  ///         (the slisBNB conversion is now a swap, not a StakeManager special case). A fair-rate
  ///         slisBNB→WBNB swap is value-neutral and the position is re-minted.
  function test_rebalance_swapExecutesThroughWhitelistedVenue() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Sell 0.5 slisBNB → WBNB at the StakeManager rate; fund the venue with the WBNB it pays out.
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    deal(WBNB, address(mockSwap), fairOut);

    bytes memory inner = abi.encodeCall(MockSwap.swap, (SLISBNB, WBNB, amountIn, fairOut, address(adapter)));
    bytes memory data = abi.encode(address(mockSwap), true, amountIn, (fairOut * 99) / 100, false, inner);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);

    assertGt(adapter.tokenId(), oldTokenId, "position re-minted after swap");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "fair swap ~value-neutral");
  }

  /// @notice The adapter only allows whitelisted swap venues; a non-whitelisted target reverts.
  function test_rebalance_revertsNotWhitelistedPair() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    MockSwap rogue = new MockSwap(); // never whitelisted
    bytes memory inner = abi.encodeCall(MockSwap.swap, (SLISBNB, WBNB, 0.5 ether, 0.5 ether, address(adapter)));
    bytes memory data = abi.encode(address(rogue), true, uint256(0.5 ether), uint256(0), false, inner);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.NotWhitelistedPair.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  /// @notice Defense-in-depth: a swap venue may never be the position's own tokens / pool / NPM.
  function test_setSwapPairWhitelist_rejectsSensitiveAddresses() public {
    address npm = address(adapter.POSITION_MANAGER());
    vm.startPrank(manager);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(SLISBNB, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(WBNB, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(POOL, true);
    vm.expectRevert(V3DexAdapter.InvalidSwapPair.selector);
    adapter.setSwapPairWhitelist(npm, true);
    vm.stopPrank();
  }

  /// @notice instantWithdraw is just another whitelisted swap venue: the StakeManager settles slisBNB→
  ///         native BNB, which the adapter wraps back to WBNB. Confirms the simplified, swap-pair-agnostic
  ///         path still supports instant-redeem (no StakeManager special-casing on chain).
  function test_rebalance_instantWithdrawAsSwapVenue() public {
    vm.prank(manager);
    adapter.setSwapPairWhitelist(STAKE_MANAGER, true);

    _deposit(user, 10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Sell 0.5 slisBNB via instantWithdraw → native BNB → wrapped to WBNB by the adapter.
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;

    bytes memory inner = abi.encodeCall(IStakeManager.instantWithdraw, (amountIn));
    bytes memory data = abi.encode(STAKE_MANAGER, true, amountIn, (fairOut * 99) / 100, false, inner);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);

    assertGt(adapter.tokenId(), oldTokenId, "position re-minted after instantWithdraw conversion");
    assertApproxEqRel(
      providerOracle.peek(address(provider)),
      peekBefore,
      2e16,
      "instantWithdraw conversion ~value-neutral"
    );
    assertEq(address(adapter).balance, 0, "native fully wrapped, none stranded");
  }

  /// @notice The backend amountOutMin is enforced on the measured output: a venue under-delivering
  ///         vs amountOutMin reverts the whole rebalance (replaces the old instant-withdraw slippage guard).
  function test_rebalance_swap_revertsBelowAmountOutMin() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    deal(WBNB, address(mockSwap), fairOut);

    // Venue pays only half, but the backend demanded the full fair output as amountOutMin.
    bytes memory inner = abi.encodeCall(MockSwap.swap, (SLISBNB, WBNB, amountIn, fairOut / 2, address(adapter)));
    bytes memory data = abi.encode(address(mockSwap), true, amountIn, fairOut, false, inner);

    vm.prank(bot);
    vm.expectRevert(SwapInventoryLib.InsufficientOutput.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  /// @notice The other swap direction (sellToken0 = false): sell WBNB → slisBNB, value-neutral.
  function test_rebalance_swapToken1ToToken0() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256 amountIn = 0.5 ether; // WBNB in
    uint256 fairOut = (amountIn * 1e18) / rate; // slisBNB out
    deal(SLISBNB, address(mockSwap), fairOut);

    bytes memory inner = abi.encodeCall(MockSwap.swap, (WBNB, SLISBNB, amountIn, fairOut, address(adapter)));
    bytes memory data = abi.encode(address(mockSwap), false, amountIn, (fairOut * 99) / 100, false, inner);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "WBNB->slisBNB swap ~value-neutral");
  }

  /// @notice Native-input venue (nativeIn=true): StakeManager.deposit{value} takes BNB. The adapter
  ///         unwraps the WBNB input → native, forwards it as msg.value, and books the minted slisBNB.
  ///         Confirms the WBNB→slisBNB-via-deposit path works (the second native direction).
  function test_rebalance_depositAsSwapVenue() public {
    vm.prank(manager);
    adapter.setSwapPairWhitelist(STAKE_MANAGER, true);

    _deposit(user, 10 ether, 10 ether);
    uint256 peekBefore = providerOracle.peek(address(provider));
    uint256 oldTokenId = adapter.tokenId();

    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Sell 0.5 WBNB → slisBNB via deposit{value}: WBNB unwrapped to BNB, deposit mints slisBNB.
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    uint256 amountIn = 0.5 ether; // WBNB in
    uint256 fairOut = (amountIn * 1e18) / rate; // slisBNB minted

    bytes memory inner = abi.encodeCall(IStakeManager.deposit, ());
    bytes memory data = abi.encode(STAKE_MANAGER, false, amountIn, (fairOut * 99) / 100, true, inner); // nativeIn=true

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);

    assertGt(adapter.tokenId(), oldTokenId, "position re-minted after deposit conversion");
    assertApproxEqRel(providerOracle.peek(address(provider)), peekBefore, 2e16, "deposit conversion ~value-neutral");
    assertEq(address(adapter).balance, 0, "native fully consumed/wrapped, none stranded");
  }

  /// @notice A venue that delivers the NATIVE coin for the non-wrapped-native output leg cannot strand
  ///         BNB: the adapter wraps it (so it isn't lost), but the expected ERC-20 output is then 0 and
  ///         the backend amountOutMin guard reverts the rebalance.
  function test_rebalance_wrongNativeOutput_reverts() public {
    NativeSwap bad = new NativeSwap();
    vm.deal(address(bad), 10 ether);
    vm.prank(manager);
    adapter.setSwapPairWhitelist(address(bad), true);

    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // sellToken0=false ⇒ tokenOut = slisBNB. The venue takes WBNB but pays native BNB (wrong leg).
    uint256 amountIn = 0.5 ether;
    bytes memory inner = abi.encodeCall(NativeSwap.swap, (WBNB, amountIn, 0.4 ether, address(adapter)));
    bytes memory data = abi.encode(address(bad), false, amountIn, uint256(0.4 ether), false, inner);

    vm.prank(bot);
    vm.expectRevert(SwapInventoryLib.InsufficientOutput.selector); // slisBNB received = 0 < amountOutMin
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  /* ─────────── rebalance after price leaves range (fully WBNB) ──────── */

  /// @dev Push pool price above tickUpper by swapping a large amount of WBNB → slisBNB.
  ///      zeroForOne = false (token1 → token0) drives the tick upward.
  ///      When tick > tickUpper the V3 position converts entirely to token1 (WBNB).
  function _pushPriceAboveRange() internal {
    PoolSwapper swapper = new PoolSwapper();
    uint256 wbnbIn = 20_000 ether;
    deal(WBNB, address(swapper), wbnbIn);
    swapper.swapExactIn(POOL, false, wbnbIn);
  }

  function test_rebalance_priceAboveRange_positionFullyWBNB() public {
    _deposit(user, 10 ether, 10 ether);

    // Push price above tickUpper — position should convert entirely to WBNB (token1).
    _pushPriceAboveRange();

    (, int24 tickAfterSwap) = IV3PoolMinimal(POOL).slot0();
    assertGt(tickAfterSwap, adapter.tickUpper(), "tick should be above tickUpper after swap");

    (uint256 total0, uint256 total1) = provider.getTotalAmounts();
    assertEq(total0, 0, "position should be fully WBNB (token0 == 0) when price is above range");
    assertGt(total1, 0, "should hold WBNB");
  }

  function test_rebalance_priceAboveRange_totalValuePreserved() public {
    _deposit(user, 10 ether, 10 ether);

    _pushPriceAboveRange();

    // Snapshot USD value before rebalance (position is 100% WBNB).
    (uint256 total0Before, uint256 total1Before) = provider.getTotalAmounts();
    uint256 valueBefore = _valueUSD(total0Before, total1Before);
    assertGt(valueBefore, 0, "should have non-zero value before rebalance");

    // The rate-derived recenter target is unaffected by a pool swap, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Rebalance uses an internally derived range; caller only supplies execution guards.
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");

    (uint256 total0After, uint256 total1After) = provider.getTotalAmounts();
    uint256 valueAfter = _valueUSD(total0After, total1After);

    // Recenter-only (empty swapData ⇒ no inventory conversion): the all-WBNB inventory is re-minted into
    // the rate-derived range (excess held as idle), so total VALUE is preserved within ~2%.
    assertApproxEqRel(valueAfter, valueBefore, 0.02e18, "recenter-only preserves total value within 2%");
  }

  /* ──────────── minAmount slippage guard tests ────────────────────── */

  /// @dev When price is below range the position is 100% slisBNB (token0).
  ///      rebalance with minAmount0 = actual slisBNB held passes; minAmount0 > actual reverts.
  function test_rebalance_priceBelowRange_minAmount0_passes() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    // rebalance's minAmount0 bounds the PRINCIPAL burned by decreaseLiquidity (fees are collected
    // separately), so size it from the liquidity principal at spot — not getTotalAmounts(), which now
    // also includes the pending fees the price-push swap accrued and would over-shoot the floor.
    (uint256 principal0, ) = adapter.amountsForLiquidity(adapter.totalLiquidity(), adapter.spotSqrtPriceX96());
    assertGt(principal0, 0, "should hold slisBNB principal before rebalance");

    // The rate-derived recenter target is unaffected by a pool swap, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // minAmount0 = principal0 (exact), minAmount1 = 0 (position has no WBNB).
    vm.prank(bot);
    provider.rebalance(principal0, 0, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");
  }

  function test_rebalance_priceBelowRange_minAmount0_tooHigh_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    (uint256 total0, ) = provider.getTotalAmounts();

    // Get past the rate-drift guard so the revert is the intended NPM slippage check.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // minAmount0 one unit above actual → should revert with NPM slippage check.
    vm.prank(bot);
    vm.expectRevert();
    provider.rebalance(total0 + 1, 0, 0, 0, block.timestamp, "");
  }

  /// @dev When price is above range the position is 100% WBNB (token1).
  ///      rebalance with minAmount1 = actual WBNB held passes; minAmount1 > actual reverts.
  function test_rebalance_priceAboveRange_minAmount1_passes() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    // minAmount1 bounds the principal burned by decreaseLiquidity (see the below-range test); size it
    // from the liquidity principal at spot, not fee-inclusive getTotalAmounts().
    (, uint256 principal1) = adapter.amountsForLiquidity(adapter.totalLiquidity(), adapter.spotSqrtPriceX96());
    assertGt(principal1, 0, "should hold WBNB principal before rebalance");

    // The rate-derived recenter target is unaffected by a pool swap, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // minAmount0 = 0 (no slisBNB), minAmount1 = principal1 (exact).
    vm.prank(bot);
    provider.rebalance(0, principal1, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");
  }

  function test_rebalance_priceAboveRange_minAmount1_tooHigh_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    (, uint256 total1) = provider.getTotalAmounts();

    // Get past the rate-drift guard so the revert is the intended NPM slippage check.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // minAmount1 one unit above actual → should revert with NPM slippage check.
    vm.prank(bot);
    vm.expectRevert();
    provider.rebalance(0, total1 + 1, 0, 0, block.timestamp, "");
  }

  function test_withdraw_minAmount_tooHigh_reverts() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 exp0, ) = provider.previewRedeemUnderlying(shares);

    vm.prank(user);
    vm.expectRevert();
    provider.withdraw(marketParams, shares, exp0 * 2, 1, user, user);
  }

  function test_redeemShares_minAmount_tooHigh_reverts() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    vm.prank(MOOLAH_PROXY);
    provider.transfer(user2, shares);

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    uint256 min0 = (exp0 * 999) / 1000;

    vm.prank(user2);
    vm.expectRevert();
    provider.redeemShares(shares, min0, exp1 * 2, user2);
  }

  /// @dev Counter-test: the removeLiquidity slippage floor must apply to the OVERALL amount delivered
  ///      (principal + fees + pro-rata idle), matching what previewRedeemUnderlying reports — not to the
  ///      burned principal alone. Previously a withdraw/redeem whose minAmount was sized from the preview
  ///      reverted (decreaseLiquidity's principal-only check) once idle was a meaningful share of the
  ///      payout. One-sided idle keeps the pre-removeLiquidity compound a no-op, so the idle survives to
  ///      be paid out — the exact condition that tripped the old floor.
  function test_redeemShares_minAmountFloor_coversIdlePayout() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    vm.prank(MOOLAH_PROXY);
    provider.transfer(user2, shares);

    // Force a one-sided idle state (token0 only) so collectAndCompound no-ops and the idle is not
    // deployed before removeLiquidity pays it out pro-rata.
    uint256 idle0 = 5 ether;
    deal(SLISBNB, address(adapter), IERC20(SLISBNB).balanceOf(address(adapter)) + idle0);
    stdstore.target(address(adapter)).sig("idleToken0()").checked_write(adapter.idleToken0() + idle0);
    stdstore.target(address(adapter)).sig("idleToken1()").checked_write(uint256(0));

    // Preview reports principal + pro-rata idle; a tight (preview-sized) floor must now pass.
    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    uint256 min0 = (exp0 * 999) / 1000;
    uint256 min1 = (exp1 * 999) / 1000;
    assertGt(exp0, 0, "preview includes idle payout");

    vm.prank(user2);
    (uint256 out0, uint256 out1) = provider.redeemShares(shares, min0, min1, user2);

    assertGe(out0, min0, "delivered token0 >= preview-derived floor (incl. idle)");
    assertGe(out1, min1, "delivered token1 >= floor");
  }

  /* ──────────── withdraw token composition by price position ─────── */

  function test_withdraw_belowRange_returnsToken0Only() public {
    // When price is below tickLower the entire position is token0.
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _pushPriceBelowRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    assertGt(exp0, 0, "previewRedeem should predict token0 below range");
    assertEq(exp1, 0, "previewRedeem should predict zero token1 below range");

    vm.prank(user);
    (uint256 out0, uint256 out1) = provider.withdraw(marketParams, shares, (exp0 * 999) / 1000, 0, user, user);

    assertGt(out0, 0, "should receive token0 when price below range");
    assertEq(out1, 0, "should receive no token1 when price below range");
  }

  function test_withdraw_aboveRange_returnsToken1Only() public {
    // When price is above tickUpper the entire position is token1.
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _pushPriceAboveRange();

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
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
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 exp0, ) = provider.previewRedeemUnderlying(shares);

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
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares, "userMarketDeposit should match shares");
    assertEq(provider.userTotalDeposit(user), shares, "userTotalDeposit should match shares");
  }

  function test_deposit_twoDeposits_accumulatesTotal() public {
    (uint256 shares1, , ) = _deposit(user, 10 ether, 10 ether);
    (uint256 shares2, , ) = _deposit(user, 10 ether, 10 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares1 + shares2, "market deposit should accumulate");
    assertEq(provider.userTotalDeposit(user), shares1 + shares2, "total deposit should accumulate");
  }

  function test_deposit_twoUsers_trackingIsIndependent() public {
    (uint256 shares1, , ) = _deposit(user, 10 ether, 10 ether);
    (uint256 shares2, , ) = _deposit(user2, 20 ether, 20 ether);

    assertEq(provider.userMarketDeposit(user, marketId), shares1);
    assertEq(provider.userTotalDeposit(user), shares1);
    assertEq(provider.userMarketDeposit(user2, marketId), shares2);
    assertEq(provider.userTotalDeposit(user2), shares2);
  }

  /* ─────────────────── slisBNBx: withdraw tracking ───────────────── */

  function test_withdraw_updatesUserMarketDeposit() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    vm.prank(user);
    provider.withdraw(marketParams, shares, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    assertEq(provider.userMarketDeposit(user, marketId), 0, "market deposit should be 0 after full withdraw");
    assertEq(provider.userTotalDeposit(user), 0, "total deposit should be 0 after full withdraw");
  }

  function test_withdraw_partial_updatesTracking() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 half = shares / 2;

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(half);
    vm.prank(user);
    provider.withdraw(marketParams, half, (exp0 * 99) / 100, (exp1 * 99) / 100, user, user);

    uint256 remaining = provider.userMarketDeposit(user, marketId);
    assertApproxEqAbs(remaining, shares - half, 1, "market deposit should halve");
    assertEq(provider.userTotalDeposit(user), remaining, "total deposit matches market deposit");
  }

  /* ─────────────────── slisBNBx: liquidate tracking ──────────────── */

  function test_liquidate_syncsBorrowerToZero() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
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

  function test_getUserBalanceInBnb_zeroBeforeDeposit() public view {
    assertEq(provider.getUserBalanceInBnb(user), 0);
  }

  function test_getUserBalanceInBnb_nonzeroAfterDeposit() public {
    _deposit(user, 10 ether, 10 ether);

    uint256 bnbValue = provider.getUserBalanceInBnb(user);
    assertGt(bnbValue, 0, "should return positive BNB value after deposit");
  }

  function test_getUserBalanceInBnb_proportionalToShares() public {
    (uint256 shares1, , ) = _deposit(user, 10 ether, 10 ether);
    (uint256 shares2, , ) = _deposit(user2, 20 ether, 20 ether);

    uint256 value1 = provider.getUserBalanceInBnb(user);
    uint256 value2 = provider.getUserBalanceInBnb(user2);

    // Each share is an equal pro-rata claim, so BNB value tracks the share count — not the raw deposit
    // amounts (equal token inputs are not equal value). Assert value2/value1 == shares2/shares1.
    assertApproxEqRel(value2 * shares1, value1 * shares2, 0.01e18, "BNB value should be proportional to shares");
  }

  function test_getUserBalanceInBnb_matchesShareValueInBnb() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

    // peek() returns (totalValue * 1e18 / supply) where totalValue is 8-dec USD.
    // getUserBalanceInBnb returns (shares * 1e18 * totalValue / supply / bnbPrice)
    //                           = shares * sharePrice / bnbPrice
    uint256 sharePrice = providerOracle.peek(address(provider)); // 8-dec USD * 1e18 / liquidity-unit
    uint256 expectedBnbValue = (shares * sharePrice) / BNB_USD;

    uint256 actualBnbValue = provider.getUserBalanceInBnb(user);
    // Allow 1% for rounding between slot0-based amounts and oracle math.
    assertApproxEqRel(actualBnbValue, expectedBnbValue, 0.01e18, "BNB value should match share oracle price");
  }

  /* ─────────────────── slisBNBx: manual sync ─────────────────────── */

  function test_syncUserBalance_noOpWhenAlreadySynced() public {
    _deposit(user, 10 ether, 10 ether);

    uint256 depositBefore = provider.userMarketDeposit(user, marketId);
    provider.syncUserBalance(marketId, user);
    assertEq(provider.userMarketDeposit(user, marketId), depositBefore, "no change when already synced");
  }

  function test_bulkSyncUserBalance_syncsMultipleUsers() public {
    _deposit(user, 10 ether, 10 ether);
    _deposit(user2, 20 ether, 20 ether);

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

    vm.expectRevert(SlisBNBV3Provider.LengthMismatch.selector);
    provider.bulkSyncUserBalance(ids, accounts);
  }

  // ── H-1 regression: foreign market ID must be rejected ────────────

  /// @dev Returns the Id of a live Moolah market whose collateralToken != address(provider).
  function _foreignMarketId() internal pure returns (Id) {
    // Use the first market in the live Moolah deployment (slisBNB / lisUSD).
    // Its collateralToken is slisBNB, not this SlisBNBV3Provider.
    MarketParams memory foreign = MarketParams({
      loanToken: LISUSD,
      collateralToken: 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B, // slisBNB
      oracle: 0xf3afD82A4071f272F403dC176916141f44E6c750, // multiOracle
      irm: 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6,
      lltv: 90 * 1e16
    });
    return foreign.id();
  }

  function test_syncUserBalance_foreignMarket_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 totalBefore = provider.userTotalDeposit(user);

    vm.expectRevert(V3Provider.InvalidMarket.selector);
    provider.syncUserBalance(_foreignMarketId(), user);

    // Deposit tracking must be unchanged.
    assertEq(provider.userTotalDeposit(user), totalBefore);
  }

  function test_bulkSyncUserBalance_foreignMarket_reverts() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 totalBefore = provider.userTotalDeposit(user);

    Id[] memory ids = new Id[](1);
    ids[0] = _foreignMarketId();
    address[] memory accounts = new address[](1);
    accounts[0] = user;

    vm.expectRevert(V3Provider.InvalidMarket.selector);
    provider.bulkSyncUserBalance(ids, accounts);

    assertEq(provider.userTotalDeposit(user), totalBefore);
  }

  /* ─────────────────── slisBNBx: minter integration ──────────────── */

  function test_withMinter_deposit_mintsSlisBNBx() public {
    SlisBNBxMinter minter = _deployMinter();
    vm.prank(manager);
    provider.setSlisBNBxMinter(address(minter));

    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);

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

    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    assertGt(ISlisBNBx(SLISBNBX).balanceOf(user), 0, "setup: slisBNBx minted after deposit");

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(shares);
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

    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 slisBNBxAfterDeposit = ISlisBNBx(SLISBNBX).balanceOf(user);
    assertGt(slisBNBxAfterDeposit, 0);

    uint256 half = shares / 2;
    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(half);
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

    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
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
    uint256 sharePrice = providerOracle.peek(address(provider)); // 8-dec USD per share
    uint256 loanPrice = providerOracle.peek(LISUSD); // 8-dec USD per lisUSD (~1e8)
    // 60% of collateral value in lisUSD units
    borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100);
    _borrow(_user, borrowed);
  }

  /// @dev Set collateral oracle price to zero, making any position with debt unhealthy.
  function _makeUnhealthy() internal {
    vm.mockCall(
      address(providerOracle),
      abi.encodeWithSelector(IOracle.peek.selector, address(provider)),
      abi.encode(uint256(0))
    );
  }

  function test_borrow_afterDeposit_receivesLisUSD() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 balBefore = IERC20(LISUSD).balanceOf(user);
    _borrow(user, 100 ether);
    assertEq(IERC20(LISUSD).balanceOf(user), balBefore + 100 ether);
    assertGt(_debtOf(user), 0, "borrow shares recorded");
  }

  function test_borrow_twoUsers_independentDebt() public {
    _deposit(user, 10 ether, 10 ether);
    _deposit(user2, 20 ether, 20 ether);
    _borrow(user, 100 ether);
    _borrow(user2, 200 ether);
    assertGt(_debtOf(user), 0);
    assertGt(_debtOf(user2), _debtOf(user), "user2 has more debt");
    assertEq(IERC20(LISUSD).balanceOf(user), 100 ether);
    assertEq(IERC20(LISUSD).balanceOf(user2), 200 ether);
  }

  function test_repay_full_clearsDebt() public {
    _deposit(user, 10 ether, 10 ether);
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
    _deposit(user, 10 ether, 10 ether);
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
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
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
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    deal(LISUSD, liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(LISUSD).approve(MOOLAH_PROXY, type(uint256).max);
    moolah.liquidate(marketParams, user, shares, 0, "");

    uint256 seizedShares = provider.balanceOf(liquidator);
    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(seizedShares);
    (uint256 out0, uint256 out1) = provider.redeemShares(
      seizedShares,
      (exp0 * 99) / 100,
      (exp1 * 99) / 100,
      liquidator
    );
    vm.stopPrank();

    assertEq(provider.balanceOf(liquidator), 0, "shares burned after redeem");
    assertGt(out0 + out1, 0, "liquidator received tokens");
    assertEq(IERC20(SLISBNB).balanceOf(liquidator), out0);
    assertEq(liquidator.balance, out1); // WBNB unwrapped to BNB
  }

  /// @notice The V3 provider no longer blocks rebalance based on spot/TWAP tick deviation.
  function test_rebalance_noLongerUsesTwapDeviationGuard() public {
    _deposit(user, 10 ether, 10 ether);

    // A pool swap does not move the StakeManager rate, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");
  }

  /* ───── rebalance without TWAP deviation guard ───── */

  function test_rebalance_succeeds_without_twap_deviation_config() public {
    _deposit(user, 10 ether, 10 ether);

    // A pool swap does not move the StakeManager rate, so disable the rate-drift guard.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");

    assertLt(adapter.tickLower(), adapter.tickUpper(), "tick range remains valid");
  }

  /* ═══════ rebalance loss-cap guards: per-swap rate floor · NAV neutrality · daily cap ═══════ */

  /// @dev Disable the rate-drift guard so rebalance is callable, and return the current StakeManager rate.
  function _prepGuardRebalance() internal returns (uint256 rate) {
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);
    rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
  }

  /// @dev Encode a slisBNB(token0)→WBNB(token1) rebalance swap through mockSwap paying exactly `amountOut`.
  function _sellToken0Data(
    uint256 amountIn,
    uint256 amountOut,
    uint256 amountOutMin
  ) internal returns (bytes memory data) {
    deal(WBNB, address(mockSwap), amountOut);
    bytes memory inner = abi.encodeCall(MockSwap.swap, (SLISBNB, WBNB, amountIn, amountOut, address(adapter)));
    data = abi.encode(address(mockSwap), true, amountIn, amountOutMin, false, inner);
  }

  function test_lossGuard_defaults() public view {
    assertEq(adapter.maxSwapLossBp(), 50_000, "per-swap cap default 5% (ppm)");
    assertEq(provider.maxRebalanceLossBp(), 20_000, "per-rebalance cap default 2% (ppm)");
    assertEq(provider.maxDailyLossUsd(), 1000e8, "daily cap default 1000 USD");
  }

  // ── per-swap rate-anchored loss cap ──

  /// @notice A compromised BOT setting amountOutMin=0 still cannot realize a swap loss beyond maxSwapLossBp.
  function test_lossGuard_perSwapCap_revertsWhenSwapLossExceedsCap() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();

    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    // Venue underpays 10% (> 5% default cap); amountOutMin=0 so the backend guard would let it through.
    bytes memory data = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SwapLossTooHigh.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  function test_lossGuard_perSwapCap_passesWithinCap() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();
    uint256 oldTokenId = adapter.tokenId();

    uint256 amountIn = 0.5 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    // 3% loss < 5% cap, amountOutMin=0 → per-swap and default NAV caps pass.
    bytes memory data = _sellToken0Data(amountIn, (fairOut * 97) / 100, 0);

    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
    assertGt(adapter.tokenId(), oldTokenId, "position re-minted (3% swap loss within 5% per-swap cap)");
  }

  // ── per-rebalance fair-NAV neutrality ──

  /// @notice Even with the per-swap cap disabled, a rebalance that drops the fair NAV beyond maxRebalanceLossBp reverts.
  function test_lossGuard_navNeutrality_revertsWhenNavDropExceedsCap() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();

    // Isolate the NAV cap: disable the per-swap cap so the lossy swap reaches the NAV check; tighten it to 0.1%.
    vm.startPrank(manager);
    adapter.setMaxSwapLossBp(1e6); // disable the per-swap cap
    provider.setMaxRebalanceLossBp(1000); // 0.1%
    vm.stopPrank();

    uint256 amountIn = 1 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    // 20% loss on 1 slisBNB ⇒ well over a 0.1% NAV drop.
    bytes memory data = _sellToken0Data(amountIn, (fairOut * 80) / 100, 0);

    vm.prank(bot);
    vm.expectRevert(V3Provider.RebalanceLossTooHigh.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  // ── per-UTC-day cumulative loss cap ──

  /// @notice With the per-swap and NAV caps disabled, the daily accumulator alone still caps a compromised BOT's total bleed.
  function test_lossGuard_dailyCap_revertsWhenDailyLossExceeded() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();

    vm.startPrank(manager);
    adapter.setMaxSwapLossBp(1e6); // disable the per-swap cap
    provider.setMaxRebalanceLossBp(1e6); // disable the per-rebalance cap (single rebalance)
    provider.setMaxDailyLossUsd(1e8); // 1 USD/day
    vm.stopPrank();

    uint256 amountIn = 1 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;
    // A 1-slisBNB swap at 20% loss ⇒ tens of USD of loss, far over the 1 USD daily cap.
    bytes memory data = _sellToken0Data(amountIn, (fairOut * 80) / 100, 0);

    vm.prank(bot);
    vm.expectRevert(V3Provider.DailyLossExceeded.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  function test_lossGuard_dailyCap_dailyAccumulatorResetsNextDay() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();

    vm.startPrank(manager);
    adapter.setMaxSwapLossBp(1e6); // disable the per-swap cap
    provider.setMaxRebalanceLossBp(1e6); // disable the per-rebalance cap
    provider.setMaxDailyLossUsd(1000e8); // generous — this test exercises the reset, not the cap
    vm.stopPrank();

    uint256 amountIn = 1 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;

    bytes memory data1 = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data1);
    uint256 accumDay1 = provider.dailyLossAccum();
    uint256 day1 = provider.dailyLossDay();
    assertGt(accumDay1, 0, "loss accrued on day 1");

    // Next UTC day: the accumulator resets, so a fresh loss is not added onto day 1's.
    vm.warp(block.timestamp + 1 days);
    bytes memory data2 = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data2);

    assertGt(provider.dailyLossDay(), day1, "UTC day advanced");
    assertLt(provider.dailyLossAccum(), (accumDay1 * 3) / 2, "accumulator reset for the new day (not doubled)");
  }

  // ── setters: access control + caps ──

  function test_lossGuard_setters_accessControlAndCaps() public {
    // per-swap cap (adapter)
    vm.prank(bot);
    vm.expectRevert();
    adapter.setMaxSwapLossBp(30_000);
    vm.prank(manager);
    vm.expectRevert(V3DexAdapter.InvalidParam.selector);
    adapter.setMaxSwapLossBp(1e6 + 1);
    vm.prank(manager);
    adapter.setMaxSwapLossBp(30_000);
    assertEq(adapter.maxSwapLossBp(), 30_000);

    // per-rebalance cap (provider)
    vm.prank(bot);
    vm.expectRevert();
    provider.setMaxRebalanceLossBp(15_000);
    vm.prank(manager);
    vm.expectRevert(V3Provider.InvalidParam.selector);
    provider.setMaxRebalanceLossBp(1e6 + 1);
    vm.prank(manager);
    provider.setMaxRebalanceLossBp(15_000);
    assertEq(provider.maxRebalanceLossBp(), 15_000);

    // daily cap (provider)
    vm.prank(bot);
    vm.expectRevert();
    provider.setMaxDailyLossUsd(500e8);
    vm.prank(manager);
    provider.setMaxDailyLossUsd(500e8);
    assertEq(provider.maxDailyLossUsd(), 500e8);
  }

  // ── audit follow-ups: same-day daily-cap accumulation, NAV-cap fail-closed, per-swap-cap sell-token1 direction ──

  /// @notice The daily cap must SUM losses across multiple same-day rebalances (guards the `+=` accumulation; a
  ///         `= loss` overwrite regression would let a compromised BOT bleed unbounded USD/day).
  function test_lossGuard_dailyCap_accumulatesSameDayAcrossRebalances() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();
    vm.startPrank(manager);
    adapter.setMaxSwapLossBp(1e6); // disable the per-swap cap
    provider.setMaxRebalanceLossBp(1e6); // disable the per-rebalance cap (single rebalance) so only the daily sum gates
    vm.stopPrank();

    uint256 amountIn = 1 ether;
    uint256 fairOut = (amountIn * rate) / 1e18;

    bytes memory d1 = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, d1);
    uint256 loss1 = provider.dailyLossAccum();
    assertGt(loss1, 0, "rebalance 1 accrued loss");

    // Cap the day at ~2.5x a single loss: rebalance 2 fits (~2x), rebalance 3 breaches (~3x).
    vm.prank(manager);
    provider.setMaxDailyLossUsd((loss1 * 5) / 2);

    bytes memory d2 = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, d2);
    // Proves cumulative `+=` (a `= loss` overwrite would leave accum ≈ loss1, failing this).
    assertGt(provider.dailyLossAccum(), (loss1 * 3) / 2, "same-day loss accumulates across rebalances");

    bytes memory d3 = _sellToken0Data(amountIn, (fairOut * 90) / 100, 0);
    vm.prank(bot);
    vm.expectRevert(V3Provider.DailyLossExceeded.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, d3);
  }

  /// @notice Fail-closed: if the feed returns 0 for a non-empty vault, rebalance must revert (not run
  ///         with the NAV/daily caps disabled). navBefore==0 is checked before adapter.rebalance, so no swap is needed.
  function test_lossGuard_navNeutrality_failsClosedOnZeroOraclePrice() public {
    _deposit(user, 10 ether, 10 ether);
    oracle.setPrice(SLISBNB, 0);
    oracle.setPrice(WBNB, 0);

    vm.prank(bot);
    vm.expectRevert(V3Provider.OracleZero.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");
  }

  /// @notice The per-swap cap also covers the sell-token1 direction (WBNB→slisBNB), exercising `_fairAmount0ForAmount1`.
  function test_lossGuard_perSwapCap_revertsOnSellToken1Loss() public {
    _deposit(user, 10 ether, 10 ether);
    uint256 rate = _prepGuardRebalance();

    uint256 amountIn = 0.5 ether; // WBNB (token1) in
    uint256 fairOut = (amountIn * 1e18) / rate; // fair slisBNB (token0) out at rate
    uint256 badOut = (fairOut * 90) / 100; // 10% loss > 5% cap
    deal(SLISBNB, address(mockSwap), badOut);
    bytes memory inner = abi.encodeCall(MockSwap.swap, (WBNB, SLISBNB, amountIn, badOut, address(adapter)));
    bytes memory data = abi.encode(address(mockSwap), false, amountIn, uint256(0), false, inner); // sellToken0=false

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SwapLossTooHigh.selector);
    provider.rebalance(0, 0, 0, 0, block.timestamp, data);
  }

  /* ───────────── Spot-vs-fair gate when adding liquidity at pool spot ───────────── */

  function test_spotDeviationGate_defaults() public view {
    assertEq(adapter.maxSpotDeviationBps(), 100, "default spot-deviation gate = 1%");
  }

  function test_setMaxSpotDeviationBps_accessAndCaps() public {
    vm.prank(manager);
    adapter.setMaxSpotDeviationBps(250);
    assertEq(adapter.maxSpotDeviationBps(), 250);

    vm.prank(manager);
    vm.expectRevert(V3DexAdapter.InvalidThreshold.selector);
    adapter.setMaxSpotDeviationBps(10_001); // > BPS

    vm.expectRevert(); // non-manager
    adapter.setMaxSpotDeviationBps(50);
  }

  /// @dev Give the adapter idle inventory to compound (mirrors test_deposit_afterIdle…).
  function _injectIdle(uint256 idle0, uint256 idle1) internal {
    deal(SLISBNB, address(adapter), IERC20(SLISBNB).balanceOf(address(adapter)) + idle0);
    deal(WBNB, address(adapter), IERC20(WBNB).balanceOf(address(adapter)) + idle1);
    stdstore.target(address(adapter)).sig("idleToken0()").checked_write(adapter.idleToken0() + idle0);
    stdstore.target(address(adapter)).sig("idleToken1()").checked_write(adapter.idleToken1() + idle1);
  }

  /// @dev Push the pool spot far above the rate-anchored fair price (sell WBNB/token1 → slisBNB/token0).
  function _skewSpotUp() internal {
    PoolSwapper swapper = new PoolSwapper();
    deal(WBNB, address(swapper), 120_000 ether);
    swapper.swapExactIn(POOL, false, 100_000 ether);
  }

  function test_compoundSkipsWhenSpotManipulated() public {
    _deposit(user, 10 ether, 10 ether);
    _injectIdle(1 ether, 50 ether);

    uint128 liqBefore = adapter.totalLiquidity();
    _skewSpotUp();

    // Permissionless compound must SKIP the re-add at the manipulated spot (no new liquidity minted).
    provider.compound();

    assertEq(adapter.totalLiquidity(), liqBefore, "compound must not add liquidity at a manipulated spot");
    assertGe(adapter.idleToken1(), 50 ether, "collected fees + old idle held as idle, never minted");
  }

  function test_compoundProceedsWhenSpotNearFair() public {
    _deposit(user, 10 ether, 10 ether);
    _injectIdle(1 ether, 50 ether);

    uint128 liqBefore = adapter.totalLiquidity();
    // No skew: the live pool spot ~ rate (fair) at the fork block, so the gate lets the compound through.
    provider.compound();

    assertGt(adapter.totalLiquidity(), liqBefore, "compound should add liquidity when spot ~ fair");
  }

  /// @dev Counter-test (one-sided idle must not brick compounding): with spot ~ fair (gate passes) but strictly one-sided idle inventory,
  ///      the computed addable liquidity is zero, which would revert inside pool.mint. _collectAndCompound
  ///      must instead hold the idle and return, so the permissionless compound() (and the deposit /
  ///      withdraw / redeemShares that reach it) is never bricked by a single-sided balance.
  function test_compound_oneSidedIdle_noOpsInsteadOfReverting() public {
    _deposit(user, 10 ether, 10 ether);
    uint128 liqBefore = adapter.totalLiquidity();

    // Force a clean one-sided idle state: token0 only, token1 exactly zero. Spot ~ fair (fork default),
    // so the spot-deviation gate passes and execution reaches the zero-liquidity no-op guard.
    uint256 idle0 = 5 ether;
    deal(SLISBNB, address(adapter), IERC20(SLISBNB).balanceOf(address(adapter)) + idle0);
    stdstore.target(address(adapter)).sig("idleToken0()").checked_write(adapter.idleToken0() + idle0);
    stdstore.target(address(adapter)).sig("idleToken1()").checked_write(uint256(0));

    provider.compound(); // must NOT revert

    assertEq(adapter.totalLiquidity(), liqBefore, "one-sided idle must not mint liquidity");
    assertGe(adapter.idleToken0(), idle0, "one-sided idle is held, not lost");
  }

  /// @dev Counter-test: positionAmountsAt used to add only the
  ///      checkpointed tokensOwed, ignoring fees accrued in the pool since the last poke — understating
  ///      every valuation built on it. The fix simulates the live feeGrowthInside delta. This fork test
  ///      cross-checks that simulated pending against the pool's ground truth: NPM.collect (which pokes
  ///      the pool) returns checkpointed owed + freshly-earned, so collected - owed must equal our
  ///      simulated pending to the wei.
  function test_positionAmountsAt_pendingFees_crossCheckedAgainstCollect() public {
    _deposit(user, 100 ether, 100 ether);

    // Accrue real swap fees to the position by trading both directions across its range.
    PoolSwapper swapper = new PoolSwapper();
    deal(WBNB, address(swapper), 5_000 ether);
    deal(SLISBNB, address(swapper), 5_000 ether);
    swapper.swapExactIn(POOL, false, 2_000 ether); // token1 -> token0 (price up)
    swapper.swapExactIn(POOL, true, 2_000 ether); // token0 -> token1 (price back down)

    uint160 fair = adapter.fairSqrtPriceX96();
    uint256 tid = adapter.tokenId();

    // Stale total = the OLD formula: principal at fair + checkpointed tokensOwed + idle (no pending).
    (, , , , , , , uint128 liq, , , uint128 owed0, uint128 owed1) = INonfungiblePositionManager(NPM).positions(tid);
    (uint256 principal0, uint256 principal1) = adapter.amountsForLiquidity(liq, fair);
    uint256 stale0 = principal0 + owed0 + adapter.idleToken0();
    uint256 stale1 = principal1 + owed1 + adapter.idleToken1();

    // With the fix, positionAmountsAt adds the simulated pending fees on top of the stale total.
    (uint256 sim0, uint256 sim1) = adapter.positionAmountsAt(fair);
    uint256 pend0 = sim0 - stale0;
    uint256 pend1 = sim1 - stale1;
    assertTrue(pend0 > 0 || pend1 > 0, "swaps must have accrued measurable pending fees");

    // Ground truth: NPM.collect pokes the pool and returns owed + freshly-earned. Snapshot so the
    // collect does not mutate the position under test.
    uint256 snap = vm.snapshotState();
    vm.prank(address(adapter));
    (uint256 col0, uint256 col1) = INonfungiblePositionManager(NPM).collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tid,
        recipient: address(adapter),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );
    assertTrue(vm.revertToState(snap), "snapshot revert failed");

    assertApproxEqAbs(pend0, col0 - owed0, 2, "simulated pending0 == actual collectable minus checkpointed");
    assertApproxEqAbs(pend1, col1 - owed1, 2, "simulated pending1 == actual collectable minus checkpointed");
  }

  /// @dev Counter-test: rebalance now takes a target pool price and reverts if the actual pool price
  ///      after the swap+mint deviates from it beyond maxSpotDeviationBps. This is what stops a price
  ///      manipulated around the rebalance (making the minLiquidity floor pass on off-market liquidity,
  ///      then sandwiched) — the minLiquidity floor alone did not.
  function test_rebalance_revertsWhenPoolPriceDeviatesFromTarget() public {
    _deposit(user, 10 ether, 10 ether);
    // Get past the rate-drift guard so execution reaches the post-mint target-deviation check.
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // BOT's target is far from the actual pool price (a stand-in for the pool being moved away from the
    // price the BOT built the rebalance against) -> must revert.
    uint160 badTarget = uint160(uint256(adapter.spotSqrtPriceX96()) * 2); // ~4x price, well beyond ±1%
    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SpotDeviationTooHigh.selector);
    provider.rebalance(0, 0, 0, badTarget, block.timestamp, "");
  }

  function test_rebalance_passesWhenPoolPriceMatchesTarget() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    // Target == the actual pool price ⇒ within the band ⇒ the deviation check passes.
    uint160 target = adapter.spotSqrtPriceX96();
    vm.prank(bot);
    provider.rebalance(0, 0, 0, target, block.timestamp, "");
    assertLt(adapter.tickLower(), adapter.tickUpper(), "recentered with a matching target");
  }

  /// @dev target == 0 opts out of the price check: the same call that reverts with a bad target
  ///      succeeds when target is 0 (parity with minAmount/minLiquidity being caller-supplied guards).
  function test_rebalance_target_zeroOptsOut() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint160 bad = uint160(uint256(adapter.spotSqrtPriceX96()) * 2);
    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SpotDeviationTooHigh.selector);
    provider.rebalance(0, 0, 0, bad, block.timestamp, "");

    // Same state, target 0 → no price check → succeeds.
    vm.prank(bot);
    provider.rebalance(0, 0, 0, 0, block.timestamp, "");
    assertLt(adapter.tickLower(), adapter.tickUpper(), "recentered with target 0");
  }

  /// @dev maxSpotDeviationBps == 0 disables the gate entirely, even for a non-zero (bad) target.
  function test_rebalance_target_disabledWhenDeviationZero() public {
    _deposit(user, 10 ether, 10 ether);
    vm.startPrank(manager);
    adapter.setCenterRateThresholdBps(0);
    adapter.setMaxSpotDeviationBps(0); // disable the gate
    vm.stopPrank();

    uint160 bad = uint160(uint256(adapter.spotSqrtPriceX96()) * 2);
    vm.prank(bot);
    provider.rebalance(0, 0, 0, bad, block.timestamp, ""); // gate off → no revert
    assertLt(adapter.tickLower(), adapter.tickUpper(), "gate disabled: bad target ignored");
  }

  /// @dev The band is two-sided: a target far ABOVE the pool price (pool price below target) reverts too.
  function test_rebalance_target_lowSideReverts() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint160 bad = uint160(uint256(adapter.spotSqrtPriceX96()) / 2); // target ~1/4 price of actual → outside band
    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SpotDeviationTooHigh.selector);
    provider.rebalance(0, 0, 0, bad, block.timestamp, "");
  }

  /// @dev A target just inside the ±band passes; the same call just outside it reverts.
  function test_rebalance_target_bandBoundary() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);
    uint256 spot = uint256(adapter.spotSqrtPriceX96());

    // maxSpotDeviationBps defaults to 100 (1% on price). sqrt·(1+0.2%) ⇒ price·~0.4% (inside);
    // sqrt·(1+0.8%) ⇒ price·~1.6% (outside).
    uint160 inside = uint160((spot * 10020) / 10000);
    uint160 outside = uint160((spot * 10080) / 10000);

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SpotDeviationTooHigh.selector);
    provider.rebalance(0, 0, 0, outside, block.timestamp, "");

    vm.prank(bot);
    provider.rebalance(0, 0, 0, inside, block.timestamp, "");
    assertLt(adapter.tickLower(), adapter.tickUpper(), "inside-band target passes");
  }

  /// @dev Realistic sandwich shape: the pool spot is pushed far from fair, the BOT passes target = fair
  ///      (the price it built the rebalance against), and the manipulated spot fails the check.
  function test_rebalance_target_sandwichRevertsWithFairTarget() public {
    _deposit(user, 10 ether, 10 ether);
    vm.prank(manager);
    adapter.setCenterRateThresholdBps(0);

    uint160 fairTarget = adapter.fairSqrtPriceX96(); // BOT's expected (rate-implied) price
    _skewSpotUp(); // attacker moves pool spot far above fair around the rebalance

    vm.prank(bot);
    vm.expectRevert(V3DexAdapter.SpotDeviationTooHigh.selector);
    provider.rebalance(0, 0, 0, fairTarget, block.timestamp, "");
  }

  /// @dev setHaircutBps is a no-op when the value is unchanged (no redundant write / misleading event).
  function test_setHaircutBps_noOpWhenUnchanged() public {
    uint256 h0 = providerOracle.haircutBps();

    vm.recordLogs();
    vm.prank(manager);
    providerOracle.setHaircutBps(h0); // unchanged → no-op
    assertEq(vm.getRecordedLogs().length, 0, "no event emitted when haircut is unchanged");
    assertEq(providerOracle.haircutBps(), h0, "haircut unchanged");

    uint256 h1 = h0 == 0 ? 50 : 0;
    vm.prank(manager);
    providerOracle.setHaircutBps(h1); // real change → applies
    assertEq(providerOracle.haircutBps(), h1, "haircut updated on a real change");
  }
}

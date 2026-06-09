// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SlisBNBV3Provider } from "../../src/provider/SlisBNBV3Provider.sol";
import { SlisBNBV3DexAdapter } from "../../src/provider/SlisBNBV3DexAdapter.sol";
import { SlisBNBV3ProviderOracle } from "../../src/provider/SlisBNBV3ProviderOracle.sol";
import { V3Liquidator } from "../../src/liquidator/V3Liquidator.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";

import { MockOneInch } from "./mocks/MockOneInch.sol";

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

contract V3LiquidatorTest is Test {
  using MarketParamsLib for MarketParams;

  /* ─────────────────── PancakeSwap V3 BSC mainnet ─────────────────── */
  address constant POOL = 0xe1B404Aaf60eEc5c8A1FEDE7dcDC0EAb9C69662F; // SLISBNB/WBNB
  address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
  uint24 constant FEE = 100;

  /* ───────────────────────────── tokens ───────────────────────────── */
  address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // token0
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // token1
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /* ──────────────────────── Moolah ecosystem ──────────────────────── */
  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant LLTV = 70 * 1e16;
  uint256 constant BNB_USD = 600e8; // 8-dec mock BNB/USD

  /* ───────────────────────── test contracts ───────────────────────── */
  Moolah moolah;
  SlisBNBV3DexAdapter adapter;
  SlisBNBV3Provider provider;
  SlisBNBV3ProviderOracle providerOracle;
  V3Liquidator liquidator;
  MockOneInch mockSwap;
  MockOracle oracle;
  MarketParams marketParams;
  Id marketId;

  /* ───────────────────────── test accounts ────────────────────────── */
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  /* ────────────────────────────── setUp ───────────────────────────── */

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    // Upgrade Moolah to the latest local implementation.
    address newImpl = address(new Moolah());
    vm.prank(TIMELOCK);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Resilient-oracle mock: WBNB = BNB price; slisBNB = BNB price × StakeManager rate; lisUSD ≈ $1.
    oracle = new MockOracle();
    uint256 rate = IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e18);
    oracle.setPrice(WBNB, BNB_USD);
    oracle.setPrice(BNB_ADDRESS, BNB_USD);
    oracle.setPrice(SLISBNB, (BNB_USD * rate) / 1e18);
    oracle.setPrice(LISUSD, 1e8);

    // Deploy the heavy 3-contract topology EARLY (adapter → provider → oracle) to avoid
    // forge setUp gas-forwarding issues with large code deposits.

    // 1) DEX adapter: sole NFT custodian + all NPM/pool writes.
    SlisBNBV3DexAdapter adapterImpl = new SlisBNBV3DexAdapter(NPM, SLISBNB, WBNB, FEE, TWAP_PERIOD);
    adapter = SlisBNBV3DexAdapter(
      payable(
        new ERC1967Proxy(address(adapterImpl), abi.encodeCall(SlisBNBV3DexAdapter.initialize, (admin, manager)))
      )
    );

    // 2) Provider / vault: ERC-4626 shares = Moolah collateral. accountingAsset = WBNB.
    SlisBNBV3Provider implP = new SlisBNBV3Provider(MOOLAH_PROXY, address(adapter));
    provider = SlisBNBV3Provider(
      payable(
        new ERC1967Proxy(
          address(implP),
          abi.encodeCall(
            SlisBNBV3Provider.initialize,
            (admin, manager, bot, address(oracle), WBNB, "V3LP SLISBNB/WBNB", "v3LP")
          )
        )
      )
    );

    // 3) Wire the adapter to the vault (one-time, admin).
    vm.prank(admin);
    adapter.setProvider(address(provider));

    // 4) Oracle: Moolah market.oracle; prices the share off the adapter's fair view.
    SlisBNBV3ProviderOracle oracleImpl = new SlisBNBV3ProviderOracle(address(adapter), address(provider), SLISBNB, WBNB);
    providerOracle = SlisBNBV3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeCall(SlisBNBV3ProviderOracle.initialize, (admin, manager, address(oracle), uint256(0)))
        )
      )
    );

    // Deploy V3Liquidator.
    V3Liquidator implL = new V3Liquidator(MOOLAH_PROXY);
    liquidator = V3Liquidator(
      payable(new ERC1967Proxy(address(implL), abi.encodeCall(V3Liquidator.initialize, (admin, manager, bot))))
    );

    mockSwap = new MockOneInch();

    // Build Moolah market: collateral = provider shares, oracle = providerOracle.
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

    // Seed lisUSD liquidity so borrows can succeed.
    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");

    // Configure liquidator whitelists.
    vm.startPrank(manager);
    liquidator.setTokenWhitelist(SLISBNB, true);
    liquidator.setTokenWhitelist(LISUSD, true);
    liquidator.setTokenWhitelist(BNB_ADDRESS, true);
    liquidator.setMarketWhitelist(Id.unwrap(marketId), true);
    liquidator.setPairWhitelist(address(mockSwap), true);
    liquidator.setV3ProviderWhitelist(address(provider), true);
    vm.stopPrank();
  }

  /* ──────────────────────── helper fns ───────────────────────────── */

  function _deposit(
    address _user,
    uint256 amount0,
    uint256 amount1
  ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
    deal(SLISBNB, _user, amount0);
    deal(WBNB, _user, amount1);
    (, uint256 exp0, uint256 exp1) = provider.previewDepositAmounts(amount0, amount1);
    vm.startPrank(_user);
    IERC20(SLISBNB).approve(address(provider), amount0);
    IERC20(WBNB).approve(address(provider), amount1);
    (shares, used0, used1) = provider.deposit(
      marketParams,
      amount0,
      amount1,
      (exp0 * 999) / 1000,
      (exp1 * 999) / 1000,
      _user
    );
    vm.stopPrank();
  }

  function _collateral(address _user) internal view returns (uint256) {
    (, , uint256 col) = moolah.position(marketId, _user);
    return col;
  }

  /// @dev Borrow 60% of user's collateral value — healthy, but mocking oracle to 0 makes it unhealthy.
  function _borrowAgainstCollateral(address _user) internal returns (uint256 borrowed) {
    (, , uint128 col) = moolah.position(marketId, _user);
    uint256 sharePrice = providerOracle.peek(address(provider));
    uint256 loanPrice = providerOracle.peek(LISUSD);
    borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100);
    vm.prank(_user);
    moolah.borrow(marketParams, borrowed, 0, _user, _user);
  }

  /// @dev Mock collateral oracle to zero, making any indebted position liquidatable.
  function _makeUnhealthy() internal {
    vm.mockCall(
      address(providerOracle),
      abi.encodeWithSelector(IOracle.peek.selector, address(provider)),
      abi.encode(uint256(0))
    );
  }

  /* ─────────────────── whitelist management ───────────────────────── */

  function test_setTokenWhitelist_togglesAndReverts() public {
    vm.prank(manager);
    liquidator.setTokenWhitelist(WBNB, true);
    assertTrue(liquidator.tokenWhitelist(WBNB));

    vm.prank(manager);
    vm.expectRevert(V3Liquidator.WhitelistSameStatus.selector);
    liquidator.setTokenWhitelist(WBNB, true);

    vm.prank(user);
    vm.expectRevert();
    liquidator.setTokenWhitelist(WBNB, false);
  }

  function test_setMarketWhitelist_toggles() public {
    bytes32 id = Id.unwrap(marketId);

    vm.prank(manager);
    liquidator.setMarketWhitelist(id, false);
    assertFalse(liquidator.marketWhitelist(id));

    vm.prank(manager);
    liquidator.setMarketWhitelist(id, true);
    assertTrue(liquidator.marketWhitelist(id));
  }

  function test_batchSetMarketWhitelist_updatesAll() public {
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = Id.unwrap(marketId);

    vm.prank(manager);
    liquidator.batchSetMarketWhitelist(ids, false);
    assertFalse(liquidator.marketWhitelist(ids[0]));

    vm.prank(manager);
    liquidator.batchSetMarketWhitelist(ids, true);
    assertTrue(liquidator.marketWhitelist(ids[0]));
  }

  function test_setPairWhitelist_togglesAndReverts() public {
    address pair = makeAddr("pair");

    vm.prank(manager);
    liquidator.setPairWhitelist(pair, true);
    assertTrue(liquidator.pairWhitelist(pair));

    vm.prank(manager);
    vm.expectRevert(V3Liquidator.WhitelistSameStatus.selector);
    liquidator.setPairWhitelist(pair, true);
  }

  function test_setV3ProviderWhitelist_togglesAndReverts() public {
    address prov = makeAddr("prov");

    vm.prank(manager);
    liquidator.setV3ProviderWhitelist(prov, true);
    assertTrue(liquidator.v3Providers(prov));

    vm.prank(manager);
    vm.expectRevert(V3Liquidator.WhitelistSameStatus.selector);
    liquidator.setV3ProviderWhitelist(prov, true);
  }

  function test_batchSetV3Providers_updatesAll() public {
    address prov1 = makeAddr("prov1");
    address prov2 = makeAddr("prov2");
    address[] memory provs = new address[](2);
    provs[0] = prov1;
    provs[1] = prov2;

    vm.prank(manager);
    liquidator.batchSetV3Providers(provs, true);
    assertTrue(liquidator.v3Providers(prov1));
    assertTrue(liquidator.v3Providers(prov2));
  }

  /* ─────────────────── access control ─────────────────────────────── */

  function test_liquidate_revertsIfNotBot() public {
    vm.prank(user);
    vm.expectRevert();
    liquidator.liquidate(Id.unwrap(marketId), user, 1, 0);
  }

  function test_flashLiquidate_revertsIfNotBot() public {
    V3Liquidator.FlashLiquidateParams memory params;
    params.v3Provider = address(provider);

    vm.prank(user);
    vm.expectRevert();
    liquidator.flashLiquidate(Id.unwrap(marketId), user, 1, params);
  }

  function test_redeemV3Shares_revertsIfNotBot() public {
    vm.prank(user);
    vm.expectRevert();
    liquidator.redeemV3Shares(address(provider), 1, 0, 0, user);
  }

  function test_sellToken_revertsIfNotBot() public {
    vm.prank(user);
    vm.expectRevert();
    liquidator.sellToken(address(mockSwap), SLISBNB, LISUSD, 1, 0, "");
  }

  /* ─────────────────── liquidate (pre-funded) ─────────────────────── */

  function test_liquidate_prefunded_receivesShares() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    deal(LISUSD, address(liquidator), 1_000 ether);

    vm.prank(bot);
    liquidator.liquidate(Id.unwrap(marketId), user, shares, 0);

    assertGt(provider.balanceOf(address(liquidator)), 0, "liquidator received shares");
    assertEq(_collateral(user), 0, "borrower collateral seized");
    assertEq(IERC20(LISUSD).allowance(address(liquidator), MOOLAH_PROXY), 0, "loanToken allowance cleared");
  }

  function test_liquidate_revertsIfMarketNotWhitelisted() public {
    vm.prank(manager);
    liquidator.setMarketWhitelist(Id.unwrap(marketId), false);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.liquidate(Id.unwrap(marketId), user, 1, 0);
  }

  /* ─────────────────── flashLiquidate ─────────────────────────────── */

  function test_flashLiquidate_holdShares_noRedeem() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 borrowed = _borrowAgainstCollateral(user);
    _makeUnhealthy();

    // Pre-fund with enough lisUSD: onMoolahLiquidate approves Moolah even when not redeeming.
    deal(LISUSD, address(liquidator), borrowed * 2);

    V3Liquidator.FlashLiquidateParams memory params = V3Liquidator.FlashLiquidateParams({
      v3Provider: address(provider),
      minToken0Amt: 0,
      minToken1Amt: 0,
      redeemShares: false,
      token0Pair: address(0),
      token0Spender: address(0),
      token1Pair: address(0),
      token1Spender: address(0),
      swapToken0Data: "",
      swapToken1Data: ""
    });

    vm.prank(bot);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, shares, params);

    assertGt(provider.balanceOf(address(liquidator)), 0, "liquidator holds seized shares");
    assertEq(_collateral(user), 0, "borrower collateral cleared");
  }

  function test_flashLiquidate_redeemAndSwap_coveredBySwapProfit() public {
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    uint256 borrowed = _borrowAgainstCollateral(user);
    _makeUnhealthy();

    // token0 (SLISBNB) swap: amountIn=0 so mock accepts any approval; produces borrowed*2 lisUSD.
    // This ensures the NoProfit check passes without knowing the exact repaidAssets upfront.
    bytes memory swap0Data = abi.encodeWithSelector(
      mockSwap.swap.selector,
      SLISBNB, // tokenIn
      LISUSD, // tokenOut
      uint256(0), // amountIn (mock pulls nothing; residual SLISBNB stays in liquidator)
      borrowed * 2 // amountOutMin — enough to cover repayment
    );

    // token1 (WBNB) swap: SlisBNBV3Provider unwraps WBNB → native BNB, V3Liquidator sends it via call{value}.
    // amountIn=0 so msg.value >= 0 always passes; MockOneInch refunds BNB to liquidator, gives 0 lisUSD.
    bytes memory swap1Data = abi.encodeWithSelector(
      mockSwap.swap.selector,
      BNB_ADDRESS, // tokenIn (native BNB path)
      LISUSD,
      uint256(0), // amountIn
      uint256(0) // no extra lisUSD needed from this leg
    );

    V3Liquidator.FlashLiquidateParams memory params = V3Liquidator.FlashLiquidateParams({
      v3Provider: address(provider),
      minToken0Amt: 0,
      minToken1Amt: 0,
      redeemShares: true,
      token0Pair: address(mockSwap),
      token0Spender: address(0),
      token1Pair: address(mockSwap),
      token1Spender: address(0),
      swapToken0Data: swap0Data,
      swapToken1Data: swap1Data
    });

    vm.prank(bot);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, shares, params);

    assertEq(provider.balanceOf(address(liquidator)), 0, "shares redeemed in callback");
    assertEq(_collateral(user), 0, "borrower collateral seized");
    // Excess lisUSD (borrowed*2 - repaidAssets ≈ borrowed) remains in liquidator.
    assertGt(IERC20(LISUSD).balanceOf(address(liquidator)), 0, "excess lisUSD in liquidator");
  }

  function test_flashLiquidate_revertsIfMarketNotWhitelisted() public {
    vm.prank(manager);
    liquidator.setMarketWhitelist(Id.unwrap(marketId), false);

    V3Liquidator.FlashLiquidateParams memory params;
    params.v3Provider = address(provider);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, 1, params);
  }

  function test_flashLiquidate_revertsIfProviderNotWhitelisted() public {
    vm.prank(manager);
    liquidator.setV3ProviderWhitelist(address(provider), false);

    V3Liquidator.FlashLiquidateParams memory params;
    params.v3Provider = address(provider);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, 1, params);
  }

  function test_flashLiquidate_revertsIfProviderMarketMismatch() public {
    // Register a second provider that is not the collateral for this market.
    address fakeProvider = makeAddr("fakeProvider");
    vm.prank(manager);
    liquidator.setV3ProviderWhitelist(fakeProvider, true);

    V3Liquidator.FlashLiquidateParams memory params;
    params.v3Provider = fakeProvider;

    vm.prank(bot);
    vm.expectRevert("provider/market mismatch");
    liquidator.flashLiquidate(Id.unwrap(marketId), user, 1, params);
  }

  /* ─────────────────── redeemV3Shares ─────────────────────────────── */

  function test_redeemV3Shares_redemeesSharesToTokens() public {
    // Acquire shares via pre-funded liquidation.
    (uint256 shares, , ) = _deposit(user, 10 ether, 10 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();
    deal(LISUSD, address(liquidator), 1_000 ether);
    vm.prank(bot);
    liquidator.liquidate(Id.unwrap(marketId), user, shares, 0);

    uint256 heldShares = provider.balanceOf(address(liquidator));
    assertGt(heldShares, 0, "setup: liquidator holds shares");

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(heldShares);

    vm.prank(bot);
    (uint256 out0, uint256 out1) = liquidator.redeemV3Shares(
      address(provider),
      heldShares,
      (exp0 * 999) / 1000,
      (exp1 * 999) / 1000,
      address(liquidator)
    );

    assertEq(provider.balanceOf(address(liquidator)), 0, "shares burned after redeem");
    assertGt(out0 + out1, 0, "tokens received");
    assertEq(IERC20(SLISBNB).balanceOf(address(liquidator)), out0, "SLISBNB received");
    assertEq(address(liquidator).balance, out1, "BNB received (WBNB unwrapped)");
  }

  function test_redeemV3Shares_revertsIfProviderNotWhitelisted() public {
    vm.prank(manager);
    liquidator.setV3ProviderWhitelist(address(provider), false);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.redeemV3Shares(address(provider), 1, 0, 0, address(liquidator));
  }

  /* ─────────────────── sell token ─────────────────────────────────── */

  function test_sellToken_erc20_swapsAndClearsAllowance() public {
    uint256 amountIn = 100 ether;
    uint256 amountOut = 50 ether;
    deal(SLISBNB, address(liquidator), amountIn);

    bytes memory swapData = abi.encodeWithSelector(mockSwap.swap.selector, SLISBNB, LISUSD, amountIn, amountOut);

    vm.prank(bot);
    liquidator.sellToken(address(mockSwap), SLISBNB, LISUSD, amountIn, amountOut, swapData);

    assertEq(IERC20(LISUSD).balanceOf(address(liquidator)), amountOut, "received lisUSD");
    assertEq(IERC20(SLISBNB).balanceOf(address(liquidator)), 0, "SLISBNB consumed");
    assertEq(IERC20(SLISBNB).allowance(address(liquidator), address(mockSwap)), 0, "allowance cleared");
  }

  function test_sellToken_revertsIfTokenNotWhitelisted() public {
    deal(WBNB, address(liquidator), 1 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.sellToken(address(mockSwap), WBNB, LISUSD, 1 ether, 0, "");
  }

  function test_sellToken_revertsIfPairNotWhitelisted() public {
    address fakePair = makeAddr("fakePair");
    deal(SLISBNB, address(liquidator), 1 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.sellToken(fakePair, SLISBNB, LISUSD, 1 ether, 0, "");
  }

  function test_sellToken_revertsIfAmountExceedsBalance() public {
    deal(SLISBNB, address(liquidator), 50 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.ExceedAmount.selector);
    liquidator.sellToken(address(mockSwap), SLISBNB, LISUSD, 100 ether, 0, "");
  }

  function test_sellBNB_swapsNativeBNB() public {
    uint256 amountIn = 1 ether;
    uint256 amountOut = 500 ether;
    deal(address(liquidator), amountIn);

    bytes memory swapData = abi.encodeWithSelector(mockSwap.swap.selector, BNB_ADDRESS, LISUSD, amountIn, amountOut);

    vm.prank(bot);
    liquidator.sellBNB(address(mockSwap), LISUSD, amountIn, amountOut, swapData);

    assertEq(IERC20(LISUSD).balanceOf(address(liquidator)), amountOut, "received lisUSD");
    assertEq(address(liquidator).balance, 0, "BNB consumed");
  }

  /* ─────────────────── withdrawals ────────────────────────────────── */

  function test_withdrawERC20_sendsToManager() public {
    uint256 amount = 100 ether;
    deal(LISUSD, address(liquidator), amount);

    vm.prank(manager);
    liquidator.withdrawERC20(LISUSD, amount);

    assertEq(IERC20(LISUSD).balanceOf(manager), amount);
    assertEq(IERC20(LISUSD).balanceOf(address(liquidator)), 0);
  }

  function test_withdrawETH_sendsToManager() public {
    uint256 amount = 1 ether;
    deal(address(liquidator), amount);

    vm.prank(manager);
    liquidator.withdrawETH(amount);

    assertEq(manager.balance, amount);
    assertEq(address(liquidator).balance, 0);
  }

  function test_withdrawERC20_revertsIfNotManager() public {
    vm.prank(user);
    vm.expectRevert();
    liquidator.withdrawERC20(LISUSD, 1);
  }
}

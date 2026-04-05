// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { V3Provider } from "../../src/provider/V3Provider.sol";
import { V3Liquidator } from "../../src/liquidator/V3Liquidator.sol";
import { IListaV3Pool } from "../../src/dex/v3/core/interfaces/IListaV3Pool.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";

import { MockOneInch } from "./mocks/MockOneInch.sol";

contract V3LiquidatorTest is Test {
  using MarketParamsLib for MarketParams;

  /* ─────────────────── PancakeSwap V3 BSC mainnet ─────────────────── */
  address constant POOL = 0x4141325bAc36aFFe9Db165e854982230a14e6d48; // USDC/WBNB
  address constant NPM = 0x7b8A01B39D58278b5DE7e48c8449c9f4F5170613;
  uint24 constant FEE = 100;

  /* ───────────────────────────── tokens ───────────────────────────── */
  address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // token0
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // token1
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /* ──────────────────────── Moolah ecosystem ──────────────────────── */
  address constant MOOLAH_PROXY = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant OPERATOR = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
  address constant MANAGER_ADDR = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant LLTV = 70 * 1e16;

  /* ───────────────────────── test contracts ───────────────────────── */
  Moolah moolah;
  V3Provider provider;
  V3Liquidator liquidator;
  MockOneInch mockSwap;
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

    // Deploy V3Provider.
    (, int24 currentTick, , , , , ) = IListaV3Pool(POOL).slot0();
    V3Provider implP = new V3Provider(MOOLAH_PROXY, NPM, USDC, WBNB, FEE, TWAP_PERIOD);
    provider = V3Provider(
      payable(
        new ERC1967Proxy(
          address(implP),
          abi.encodeCall(
            V3Provider.initialize,
            (admin, manager, bot, RESILIENT_ORACLE, currentTick - 500, currentTick + 500, "V3LP USDC/WBNB", "v3LP")
          )
        )
      )
    );

    // Deploy V3Liquidator.
    V3Liquidator implL = new V3Liquidator(MOOLAH_PROXY);
    liquidator = V3Liquidator(
      payable(new ERC1967Proxy(address(implL), abi.encodeCall(V3Liquidator.initialize, (admin, manager, bot))))
    );

    mockSwap = new MockOneInch();

    // Build Moolah market: collateral = provider shares, oracle = provider.
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

    // Seed lisUSD liquidity so borrows can succeed.
    deal(LISUSD, address(this), 1_000_000 ether);
    IERC20(LISUSD).approve(MOOLAH_PROXY, 1_000_000 ether);
    moolah.supply(marketParams, 1_000_000 ether, 0, address(this), "");

    // Configure liquidator whitelists.
    vm.startPrank(manager);
    liquidator.setTokenWhitelist(USDC, true);
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
    deal(USDC, _user, amount0);
    deal(WBNB, _user, amount1);
    (, uint256 exp0, uint256 exp1) = provider.previewDeposit(amount0, amount1);
    vm.startPrank(_user);
    IERC20(USDC).approve(address(provider), amount0);
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
    uint256 sharePrice = provider.peek(address(provider));
    uint256 loanPrice = provider.peek(LISUSD);
    borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100);
    vm.prank(_user);
    moolah.borrow(marketParams, borrowed, 0, _user, _user);
  }

  /// @dev Mock collateral oracle to zero, making any indebted position liquidatable.
  function _makeUnhealthy() internal {
    vm.mockCall(
      address(provider),
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
    liquidator.sellToken(address(mockSwap), USDC, LISUSD, 1, 0, "");
  }

  /* ─────────────────── liquidate (pre-funded) ─────────────────────── */

  function test_liquidate_prefunded_receivesShares() public {
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
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
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
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
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    uint256 borrowed = _borrowAgainstCollateral(user);
    _makeUnhealthy();

    // token0 (USDC) swap: amountIn=0 so mock accepts any approval; produces borrowed*2 lisUSD.
    // This ensures the NoProfit check passes without knowing the exact repaidAssets upfront.
    bytes memory swap0Data = abi.encodeWithSelector(
      mockSwap.swap.selector,
      USDC, // tokenIn
      LISUSD, // tokenOut
      uint256(0), // amountIn (mock pulls nothing; residual USDC stays in liquidator)
      borrowed * 2 // amountOutMin — enough to cover repayment
    );

    // token1 (WBNB) swap: V3Provider unwraps WBNB → native BNB, V3Liquidator sends it via call{value}.
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
    (uint256 shares, , ) = _deposit(user, 1_000 ether, 3 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();
    deal(LISUSD, address(liquidator), 1_000 ether);
    vm.prank(bot);
    liquidator.liquidate(Id.unwrap(marketId), user, shares, 0);

    uint256 heldShares = provider.balanceOf(address(liquidator));
    assertGt(heldShares, 0, "setup: liquidator holds shares");

    (uint256 exp0, uint256 exp1) = provider.previewRedeem(heldShares);

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
    assertEq(IERC20(USDC).balanceOf(address(liquidator)), out0, "USDC received");
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
    deal(USDC, address(liquidator), amountIn);

    bytes memory swapData = abi.encodeWithSelector(mockSwap.swap.selector, USDC, LISUSD, amountIn, amountOut);

    vm.prank(bot);
    liquidator.sellToken(address(mockSwap), USDC, LISUSD, amountIn, amountOut, swapData);

    assertEq(IERC20(LISUSD).balanceOf(address(liquidator)), amountOut, "received lisUSD");
    assertEq(IERC20(USDC).balanceOf(address(liquidator)), 0, "USDC consumed");
    assertEq(IERC20(USDC).allowance(address(liquidator), address(mockSwap)), 0, "allowance cleared");
  }

  function test_sellToken_revertsIfTokenNotWhitelisted() public {
    deal(WBNB, address(liquidator), 1 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.sellToken(address(mockSwap), WBNB, LISUSD, 1 ether, 0, "");
  }

  function test_sellToken_revertsIfPairNotWhitelisted() public {
    address fakePair = makeAddr("fakePair");
    deal(USDC, address(liquidator), 1 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    liquidator.sellToken(fakePair, USDC, LISUSD, 1 ether, 0, "");
  }

  function test_sellToken_revertsIfAmountExceedsBalance() public {
    deal(USDC, address(liquidator), 50 ether);

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.ExceedAmount.selector);
    liquidator.sellToken(address(mockSwap), USDC, LISUSD, 100 ether, 0, "");
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

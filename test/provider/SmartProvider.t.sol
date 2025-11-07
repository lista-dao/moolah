pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import { SmartProvider } from "../../src/provider/SmartProvider.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapPoolInfo } from "../../src/dex/StableSwapPoolInfo.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "../../src/dex/StableSwapLPCollateral.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";
import { StableSwapFactory } from "../../src/dex/StableSwapFactory.sol";
import { Liquidator } from "../../src/liquidator/Liquidator.sol";
import { PublicLiquidator } from "../../src/liquidator/PublicLiquidator.sol";
import { MockOneInch } from "../liquidator/mocks/MockOneInch.sol";

contract SmartProviderTest is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  SmartProvider smartProvider;
  StableSwapFactory factory;
  StableSwapPool dex;
  StableSwapPoolInfo dexInfo;
  StableSwapLP lp; // ss-lp
  StableSwapLPCollateral lpCollateral; // ss-lp collateral

  Liquidator liquidator;
  PublicLiquidator publicLiquidator;

  ERC20Mock token0;
  address token1 = BNB_ADDRESS; // BNB

  Moolah moolah;
  address moolahProxy = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C; // MoolahProxy
  MoolahVault usdtVault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address curator = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;

  MarketParams marketParams;

  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");
  address userC = makeAddr("userC");
  address pauser = makeAddr("pauser");
  address deployer1 = makeAddr("deployer1");
  address deployer2 = makeAddr("deployer2");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    // Upgrade Moolah
    address newImlp = address(new Moolah());
    vm.startPrank(admin);
    UUPSUpgradeable proxy3 = UUPSUpgradeable(moolahProxy);
    proxy3.upgradeToAndCall(newImlp, bytes(""));
    //    assertEq(getImplementation(moolahProxy), newImlp);
    vm.stopPrank();
    moolah = Moolah(moolahProxy);

    // Deploy Dex
    deployDexBnb();

    // Deploy LP Collateral
    lpCollateral = new StableSwapLPCollateral(moolahProxy);
    ERC1967Proxy lpCollateralProxy = new ERC1967Proxy(
      address(lpCollateral),
      abi.encodeWithSelector(lpCollateral.initialize.selector, admin, address(this), lp.name(), lp.symbol())
    );
    lpCollateral = StableSwapLPCollateral(address(lpCollateralProxy));

    // Deploy Smart Provider
    smartProvider = new SmartProvider(address(moolahProxy), address(lpCollateral));
    ERC1967Proxy smartProviderProxy = new ERC1967Proxy(
      address(smartProvider),
      abi.encodeWithSelector(smartProvider.initialize.selector, admin, address(dex), address(dexInfo), multiOracle)
    );
    smartProvider = SmartProvider(payable(address(smartProviderProxy)));

    // Deploy Liquidator
    Liquidator liquidatorImpl = new Liquidator(address(moolahProxy));
    ERC1967Proxy liquidatorProxy = new ERC1967Proxy(
      address(liquidatorImpl),
      abi.encodeWithSelector(liquidatorImpl.initialize.selector, admin, manager, bot)
    );
    liquidator = Liquidator(payable(address(liquidatorProxy)));

    // Deploy Public Liquidator
    PublicLiquidator publicLiquidatorImpl = new PublicLiquidator(address(moolahProxy));
    ERC1967Proxy publicLiquidatorProxy = new ERC1967Proxy(
      address(publicLiquidatorImpl),
      abi.encodeWithSelector(publicLiquidatorImpl.initialize.selector, admin, manager, bot)
    );
    publicLiquidator = PublicLiquidator(payable(address(publicLiquidatorProxy)));

    // set minter for lp collateral
    vm.prank(admin);
    lpCollateral.setMinter(address(smartProvider));
    assertEq(lpCollateral.MOOLAH(), address(moolah));
    assertEq(lpCollateral.minter(), address(smartProvider));

    // create market
    createMarket();

    // set liquidator
    vm.startPrank(manager);
    moolah.addLiquidationWhitelist(marketParams.id(), address(liquidator));
    moolah.addLiquidationWhitelist(marketParams.id(), address(publicLiquidator));
    liquidator.setTokenWhitelist(address(lp), true);
    liquidator.setMarketWhitelist(Id.unwrap(marketParams.id()), true);
    vm.stopPrank();

    vm.prank(bot);
    publicLiquidator.setMarketWhitelist(Id.unwrap(marketParams.id()), true);
  }

  function deployDexBnb() public {
    dexInfo = new StableSwapPoolInfo();
    address[] memory deployers = new address[](2);
    deployers[0] = deployer1;
    deployers[1] = deployer2;
    StableSwapFactory factoryImpl = new StableSwapFactory();
    ERC1967Proxy factoryProxy = new ERC1967Proxy(
      address(factoryImpl),
      abi.encodeWithSelector(factoryImpl.initialize.selector, admin, deployers)
    );
    factory = StableSwapFactory(address(factoryProxy));

    assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(factory.hasRole(factory.DEPLOYER(), deployer1));
    assertTrue(factory.hasRole(factory.DEPLOYER(), deployer2));

    token0 = new ERC20Mock();

    token0.setBalance(userA, 10000000 ether);
    deal(userA, 10000000 ether); // Give userA 10_000_000 BNB

    token0.setBalance(userB, 10000000 ether);
    deal(userC, 10000000 ether); // Give userC 10_000_000 BNB

    // initialize parameters
    address[2] memory tokens;
    tokens[0] = address(token0);
    tokens[1] = token1; // BNB_ADDRESS

    uint _A = 1000; // Amplification coefficient
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 5e9; // 50% swap fee goes to admin

    // mock oracle calls; token0 (slisBnb) price = $846.6; token1 (BNB) price = $830, rate = 1.02
    vm.mockCall(multiOracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(8466e7));
    vm.mockCall(multiOracle, abi.encodeWithSelector(IOracle.peek.selector, token1), abi.encode(830e8));
    vm.mockCall(multiOracle, abi.encodeWithSelector(IOracle.peek.selector, WBNB), abi.encode(830e8));

    vm.mockCall(multiOracle, abi.encodeWithSelector(IOracle.peek.selector, USDT), abi.encode(1e8));

    address lpImpl = address(new StableSwapLP());
    address poolImpl = address(new StableSwapPool(address(factory)));
    vm.startPrank(admin);
    factory.setLpImpl(lpImpl);
    factory.setSwapImpl(poolImpl);
    vm.stopPrank();
    assertEq(factory.lpImpl(), lpImpl);
    assertEq(factory.swapImpl(), poolImpl);

    vm.startPrank(deployer1);
    (address _lp, address _pool) = factory.createSwapPair(
      address(token0),
      token1,
      "StableSwap LP Token",
      "ss-LP",
      _A,
      _fee,
      _adminFee,
      admin,
      manager,
      pauser,
      multiOracle
    );
    vm.stopPrank();

    lp = StableSwapLP(_lp);
    dex = StableSwapPool(_pool);

    seedPool();
  }

  function seedPool() public {
    vm.startPrank(userA);

    // Add liquidity
    uint ratio = (8466 * 10 ** 17) / 830; // slisBnb price ratio to BNB
    uint256 amount0 = 100_000 * ratio; // slisBnb amount, based on the price ratio
    uint256 amount1 = 100_000 ether; // Bnb

    // Approve tokens for the pool
    token0.approve(address(dex), amount0);

    uint min_mint_amount = 0;
    dex.add_liquidity{ value: amount1 }([amount0, amount1], min_mint_amount);

    // Check LP balance
    uint256 lpAmount = lp.balanceOf(userA);
    assertEq(lpAmount, 201999990107932736938407); // 2000 LP tokens minted (1:1 ratio for simplicity)

    assertEq(lp.totalSupply(), 201999990107932736938407); // Total supply of LP tokens

    vm.stopPrank();
  }

  function createMarket() public {
    address operator = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;
    vm.prank(operator);
    marketParams = MarketParams({
      loanToken: USDT,
      collateralToken: address(lpCollateral),
      oracle: address(smartProvider), // use smart provider as oracle
      irm: irm,
      lltv: lltv70
    });
    moolah.createMarket(marketParams);
  }

  function test_supplyDexLp() public {
    // user2 supply 1000 LP tokens as collateral
    uint256 supplyAmount = 1000 ether;

    deal(address(lp), user2, supplyAmount);

    vm.startPrank(user2);
    vm.expectRevert();
    smartProvider.supplyDexLp(marketParams, user2, supplyAmount);
    vm.expectRevert("zero lp amount");
    smartProvider.supplyDexLp(marketParams, user2, 0);

    lp.approve(address(smartProvider), supplyAmount);
    smartProvider.supplyDexLp(marketParams, user2, supplyAmount);

    // Check lp balance and collateral minting
    uint256 mintedLp = lp.balanceOf(address(smartProvider));
    assertEq(mintedLp, supplyAmount);
    assertEq(lpCollateral.totalSupply(), mintedLp);
    uint256 lpCollateralBalance = lpCollateral.balanceOf(address(moolah));
    assertEq(lpCollateralBalance, mintedLp);
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Collateral, mintedLp);

    vm.stopPrank();
  }

  function test_supplyCollateral_perfect() public {
    // user2 supply 1000 LP tokens as collateral
    uint256 supplyAmount = 1000 ether;

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), supplyAmount);

    deal(address(token0), user2, amounts[0]);
    deal(user2, amounts[1]);

    vm.startPrank(user2);
    token0.approve(address(smartProvider), amounts[0]);
    vm.expectRevert("amount1 should equal msg.value");
    smartProvider.supplyCollateral(marketParams, user2, amounts[0], amounts[1], supplyAmount);
    vm.expectRevert("amount1 should equal msg.value");
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      0, // invalid amount
      supplyAmount
    );

    vm.expectRevert("Slippage screwed you");
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      amounts[1],
      supplyAmount // revert on exact amount due to rounding issue
    );

    // succeed
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      amounts[1],
      supplyAmount - 10 // minus 10 wei to avoid rounding issue
    );

    // Check lp balance and collateral minting
    uint256 mintedLp = lp.balanceOf(address(smartProvider));
    assertApproxEqAbs(mintedLp, supplyAmount, 2); // allow 2 wei difference due to rounding
    assertEq(lpCollateral.totalSupply(), mintedLp);
    uint256 lpCollateralBalance = lpCollateral.balanceOf(address(moolah));
    assertEq(lpCollateralBalance, mintedLp);
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Collateral, mintedLp);

    vm.stopPrank();
  }

  function test_borrow_usdt() public {
    vm.prank(curator);
    usdtVault.setCap(marketParams, 10_000_000_000 ether);

    uint len = usdtVault.supplyQueueLength();
    Id[] memory supplyQueue = new Id[](len + 1);
    for (uint256 i = 0; i < len; i++) {
      supplyQueue[i] = usdtVault.supplyQueue(i);
    }
    supplyQueue[len] = marketParams.id();
    vm.prank(allocator);
    usdtVault.setSupplyQueue(supplyQueue);

    // userA supply 10_000_000_000 USDT to vault
    uint256 supplyAmount = 10_000_000_000 ether;
    deal(USDT, userA, supplyAmount);
    vm.startPrank(userA);
    IERC20(USDT).approve(address(usdtVault), supplyAmount);
    usdtVault.deposit(supplyAmount, userA);
    vm.stopPrank();

    (
      uint128 totalSupplyAssets,
      uint128 totalSupplyShares,
      uint128 totalBorrowAssets,
      uint128 totalBorrowShares,
      uint128 lastUpdate,
      uint128 fee
    ) = moolah.market(marketParams.id());

    test_supplyCollateral_perfect();
    // user2 borrow 500 USDT
    uint256 borrowAmount = 500 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);
    (, uint256 user2Debt, ) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, borrowAmount * 1e6);

    (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee) = moolah.market(
      marketParams.id()
    );
    assertEq(totalBorrowAssets * 1e6, user2Debt);
  }

  function test_liquidate_via_liquidator() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    (, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(bot);
    deal(USDT, bot, user2Debt + 1000 ether);
    deal(USDT, address(liquidator), user2Debt + 1000 ether);
    IERC20(USDT).approve(address(moolah), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%
    bytes memory payload = abi.encode(minAmount0, minAmount1);

    vm.stopPrank();

    vm.startPrank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);
    liquidator.batchSetSmartProviders(providers, true);
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));
    assertTrue(liquidator.smartProviders(address(smartProvider)));
    vm.stopPrank();

    uint256 usdtBefore = IERC20(USDT).balanceOf(address(liquidator));
    vm.startPrank(bot);
    (uint256 _seizedAssets, uint256 _repaidAssets) = liquidator.liquidateSmartCollateral(
      Id.unwrap(marketParams.id()),
      user2,
      address(smartProvider),
      user2Collateral,
      0,
      payload
    );
    assertEq(user2Collateral, _seizedAssets);

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertApproxEqAbs(token0.balanceOf(address(liquidator)), amounts[0], 2); // allow 2 wei difference due to rounding
    assertApproxEqAbs(address(liquidator).balance, amounts[1], 2); // allow 2 wei difference due to rounding
    uint256 usdtAfter = IERC20(USDT).balanceOf(address(liquidator));
    assertEq(usdtAfter, usdtBefore - _repaidAssets);
  }

  function test_liquidate_via_public_liquidator() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    (, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(user2);
    deal(USDT, user2, user2Debt + 1000 ether);
    IERC20(USDT).approve(address(publicLiquidator), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%
    bytes memory payload = abi.encode(minAmount0, minAmount1);
    vm.stopPrank();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    uint256 usdtBefore = IERC20(USDT).balanceOf(user2);
    vm.startPrank(user2);
    (uint256 _seizedAssets, uint256 _repaidAssets) = publicLiquidator.liquidateSmartCollateral(
      Id.unwrap(marketParams.id()),
      user2,
      address(smartProvider),
      user2Collateral,
      0,
      payload
    );
    assertEq(user2Collateral, _seizedAssets);

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertApproxEqAbs(token0.balanceOf(user2), amounts[0], 2); // allow 2 wei difference due to rounding
    assertApproxEqAbs(user2.balance, amounts[1], 2); // allow 2 wei difference due to rounding
    uint256 usdtAfter = IERC20(USDT).balanceOf(user2);
    assertEq(usdtAfter, usdtBefore - _repaidAssets);
  }

  function test_flash_liquidate_via_liquidator() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    (, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(bot);
    deal(USDT, bot, user2Debt + 1000 ether);
    deal(USDT, address(liquidator), user2Debt + 1000 ether);
    IERC20(USDT).approve(address(moolah), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%
    bytes memory payload = abi.encode(minAmount0, minAmount1);

    vm.stopPrank();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    address token0Pair = address(new MockOneInch());
    address token1Pair = address(new MockOneInch());
    vm.startPrank(manager);
    liquidator.setPairWhitelist(token0Pair, true);
    liquidator.setPairWhitelist(token1Pair, true);
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);
    liquidator.batchSetSmartProviders(providers, true);
    vm.stopPrank();
    bytes memory swapToken0Data = abi.encodeWithSelector(
      MockOneInch.swap.selector,
      address(token0),
      USDT,
      amounts[0],
      user2Debt / 2 // min USDT out
    );

    bytes memory swapToken1Data = abi.encodeWithSelector(
      MockOneInch.swap.selector,
      BNB_ADDRESS,
      USDT,
      amounts[1],
      user2Debt / 2 // min USDT out
    );

    uint256 loanBeforeLiq = IERC20(USDT).balanceOf(address(liquidator));
    uint256 loanBeforeMoolah = IERC20(USDT).balanceOf(address(moolah));
    vm.startPrank(bot);
    (uint256 _seizedAssets, uint256 _repaidAssets) = liquidator.flashLiquidateSmartCollateral(
      Id.unwrap(marketParams.id()),
      user2,
      address(smartProvider),
      user2Collateral,
      token0Pair,
      token1Pair,
      swapToken0Data,
      swapToken1Data,
      payload
    );
    assertEq(user2Collateral, _seizedAssets);

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    uint256 loanAfterLiq = IERC20(USDT).balanceOf(address(liquidator));
    assertEq(loanAfterLiq, loanBeforeLiq + user2Debt - _repaidAssets);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertEq(token0.balanceOf(address(liquidator)), 0);
    assertEq(address(liquidator).balance, 0);
    uint256 loanAfterMoolah = IERC20(USDT).balanceOf(address(moolah));
    assertEq(loanAfterMoolah, loanBeforeMoolah + _repaidAssets);
  }

  // Bot call `Liquidator.liquidate` first, then call `Liquidator.redeemSmartCollateral` to redeem token0 and token1
  function test_liquidate_via_liquidator_by_bot() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    (, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(bot);
    deal(USDT, bot, user2Debt + 1000 ether);
    deal(USDT, address(liquidator), user2Debt + 1000 ether);
    IERC20(USDT).approve(address(moolah), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%

    vm.stopPrank();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    uint256 usdtBefore = IERC20(USDT).balanceOf(address(liquidator));

    // step 1: liquidate
    vm.startPrank(bot);
    liquidator.liquidate(Id.unwrap(marketParams.id()), user2, user2Collateral, 0);
    uint256 _repaidAssets = usdtBefore - IERC20(USDT).balanceOf(address(liquidator));

    // step 2: redeem token0 and token1
    vm.expectRevert("NotWhitelisted()");
    liquidator.redeemSmartCollateral(
      address(smartProvider),
      user2Collateral, // lpAmount
      minAmount0,
      minAmount1
    );
    vm.stopPrank();
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);
    vm.prank(manager);
    liquidator.batchSetSmartProviders(providers, true);
    assertTrue(liquidator.smartProviders(address(smartProvider)));

    vm.prank(bot);
    liquidator.redeemSmartCollateral(
      address(smartProvider),
      user2Collateral, // lpAmount
      minAmount0,
      minAmount1
    );

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertApproxEqAbs(token0.balanceOf(address(liquidator)), amounts[0], 2); // allow 2 wei difference due to rounding
    assertApproxEqAbs(address(liquidator).balance, amounts[1], 2); // allow 2 wei difference due to rounding
    uint256 usdtAfter = IERC20(USDT).balanceOf(address(liquidator));
    assertEq(usdtAfter, usdtBefore - _repaidAssets);
  }

  function test_flash_liquidate_via_public_liquidator() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    (, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(bot);
    deal(USDT, user2, user2Debt + 1000 ether);
    IERC20(USDT).approve(address(moolah), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%
    bytes memory payload = abi.encode(minAmount0, minAmount1);

    vm.stopPrank();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    address token0Pair = address(new MockOneInch());
    address token1Pair = address(new MockOneInch());
    bytes memory swapToken0Data = abi.encodeWithSelector(
      MockOneInch.swap.selector,
      address(token0),
      USDT,
      amounts[0],
      user2Debt / 2 // min USDT out
    );

    bytes memory swapToken1Data = abi.encodeWithSelector(
      MockOneInch.swap.selector,
      BNB_ADDRESS,
      USDT,
      amounts[1],
      user2Debt / 2 // min USDT out
    );

    uint256 loanBefore = IERC20(USDT).balanceOf(user2);
    uint256 loanBeforeMoolah = IERC20(USDT).balanceOf(address(moolah));
    vm.startPrank(user2);
    vm.expectRevert("NotWhitelisted()");
    (uint256 _seizedAssets, uint256 _repaidAssets) = publicLiquidator.flashLiquidateSmartCollateral(
      Id.unwrap(marketParams.id()),
      user2,
      address(smartProvider),
      user2Collateral,
      token0Pair,
      token1Pair,
      swapToken0Data,
      swapToken1Data,
      payload
    );
    vm.stopPrank();

    // whitelist pairs
    vm.startPrank(manager);
    publicLiquidator.setPairWhitelist(token0Pair, true);
    publicLiquidator.setPairWhitelist(token1Pair, true);
    vm.stopPrank();
    assertTrue(publicLiquidator.pairWhitelist(token0Pair));
    assertTrue(publicLiquidator.pairWhitelist(token1Pair));

    vm.startPrank(user2);
    (_seizedAssets, _repaidAssets) = publicLiquidator.flashLiquidateSmartCollateral(
      Id.unwrap(marketParams.id()),
      user2,
      address(smartProvider),
      user2Collateral,
      token0Pair,
      token1Pair,
      swapToken0Data,
      swapToken1Data,
      payload
    );

    assertEq(user2Collateral, _seizedAssets);

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    uint256 loanAfter = IERC20(USDT).balanceOf(user2);
    assertEq(loanAfter, loanBefore + user2Debt - _repaidAssets);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertEq(token0.balanceOf(address(publicLiquidator)), 0);
    assertEq(address(publicLiquidator).balance, 0);
    uint256 loanAfterMoolah = IERC20(USDT).balanceOf(address(moolah));
    assertEq(loanAfterMoolah, loanBeforeMoolah + _repaidAssets);
  }

  function test_repay_usdt() public {
    test_borrow_usdt();

    skip(10 days);

    vm.startPrank(user2);
    moolah.accrueInterest(marketParams);
    (, uint128 user2Debt, ) = moolah.position(marketParams.id(), user2);
    uint256 repayAmount = 100 ether;
    (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = moolah.market(marketParams.id());
    uint256 repayShares = repayAmount.toSharesUp(totalBorrowAssets, totalBorrowShares);

    deal(USDT, user2, repayAmount);
    IERC20(USDT).approve(address(moolah), repayAmount);
    moolah.repay(marketParams, repayAmount, 0, user2, bytes(""));
    (, uint256 user2DebtAfter, ) = moolah.position(marketParams.id(), user2);
    (, , uint128 totalBorrowAssetsAfter, uint128 totalBorrowSharesAfter, , ) = moolah.market(marketParams.id());

    assertApproxEqAbs(user2DebtAfter, user2Debt - repayShares, 2); // allow 2 wei difference due to rounding
    assertEq(totalBorrowAssetsAfter, totalBorrowAssets - repayAmount);
    assertApproxEqAbs(totalBorrowSharesAfter, totalBorrowShares - repayShares, 2); // allow 2 wei difference due to rounding
  }

  function test_repayAll_usdt() public {
    test_borrow_usdt();

    skip(10 days);

    vm.startPrank(user2);
    moolah.accrueInterest(marketParams);
    (, uint128 user2Debt, ) = moolah.position(marketParams.id(), user2);

    deal(USDT, user2, user2Debt / 1e6 + 1 ether);
    IERC20(USDT).approve(address(moolah), user2Debt / 1e6 + 1 ether);
    moolah.repay(marketParams, 0, user2Debt, user2, bytes(""));
    (, uint256 user2DebtAfter, ) = moolah.position(marketParams.id(), user2);
    (, , uint128 totalBorrowAssetsAfter, uint128 totalBorrowSharesAfter, , ) = moolah.market(marketParams.id());

    assertEq(user2DebtAfter, 0);
    assertEq(totalBorrowAssetsAfter, 0);
    assertEq(totalBorrowSharesAfter, 0);
  }

  function test_withdrawCollateral_perfect() public {
    test_repayAll_usdt();

    vm.startPrank(user2);
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    uint256 withdrawAmount = user2Collateral / 2;
    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), withdrawAmount);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%

    uint256 token0Balance = token0.balanceOf(user2);
    uint256 bnbBalance = user2.balance;
    uint256 totalSupplyBefore = lp.totalSupply();
    vm.expectRevert("unauthorized");
    smartProvider.withdrawCollateral(marketParams, withdrawAmount, minAmount0, minAmount1, user2, payable(user2));
    vm.stopPrank();
    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    vm.prank(user2);
    smartProvider.withdrawCollateral(marketParams, withdrawAmount, minAmount0, minAmount1, user2, payable(user2));
    (, , uint256 user2CollateralAfter) = moolah.position(marketParams.id(), user2);

    assertEq(user2CollateralAfter, user2Collateral - withdrawAmount);
    assertEq(lpCollateral.balanceOf(address(moolah)), user2CollateralAfter);
    assertEq(lpCollateral.totalSupply(), user2CollateralAfter);

    assertEq(lp.balanceOf(address(smartProvider)), user2CollateralAfter);
    assertEq(lp.totalSupply(), totalSupplyBefore - withdrawAmount);

    uint256 token0Received = token0.balanceOf(user2) - token0Balance;
    uint256 bnbReceived = user2.balance - bnbBalance;
    assertApproxEqAbs(token0Received, amounts[0], 2); // allow 2 wei difference due to rounding
    assertApproxEqAbs(bnbReceived, amounts[1], 2); // allow 2 wei difference due to rounding
  }

  function test_withdrawCollateral_imbalance() public {
    test_repayAll_usdt();
    vm.startPrank(user2);
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    uint256[2] memory amounts = [uint256(1 ether), uint256(0.5 ether)]; // force imbalance withdrawal
    uint256 maxBurnAmount = dex.calc_token_amount(amounts, false);
    maxBurnAmount = maxBurnAmount + (maxBurnAmount * 5) / 1000; // add 0.5% slippage

    uint256 token0Balance = token0.balanceOf(user2);
    uint256 bnbBalance = user2.balance;
    uint256 totalSupplyBefore = lp.totalSupply();
    vm.expectRevert("unauthorized");
    smartProvider.withdrawCollateralImbalance(
      marketParams,
      amounts[0],
      amounts[1],
      maxBurnAmount,
      user2,
      payable(user2)
    );
    vm.stopPrank();
    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    vm.prank(user2);
    smartProvider.withdrawCollateralImbalance(
      marketParams,
      amounts[0],
      amounts[1],
      maxBurnAmount,
      user2,
      payable(user2)
    );
    (, , uint256 user2CollateralAfter) = moolah.position(marketParams.id(), user2);

    // TODO: get exact withdraw amount from log
    uint256 withdrawAmount = totalSupplyBefore - lp.totalSupply();
    assertEq(user2CollateralAfter, user2Collateral - withdrawAmount);
    assertEq(lpCollateral.balanceOf(address(moolah)), user2CollateralAfter);
    assertEq(lpCollateral.totalSupply(), user2CollateralAfter);

    assertEq(lp.balanceOf(address(smartProvider)), user2CollateralAfter);
    assertEq(lp.totalSupply(), totalSupplyBefore - withdrawAmount);

    uint256 token0Received = token0.balanceOf(user2) - token0Balance;
    uint256 bnbReceived = user2.balance - bnbBalance;
    assertEq(token0Received, amounts[0]);
    assertEq(bnbReceived, amounts[1]);
  }

  function test_withdrawCollateral_oneCoin() public {
    test_repayAll_usdt();
    vm.startPrank(user2);
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    uint256 withdrawAmount = user2Collateral / 2;
    // withdraw BNB only
    uint256 expectBnbAmt = dex.calc_withdraw_one_coin(withdrawAmount, 1);

    uint256 token0Balance = token0.balanceOf(user2);
    uint256 bnbBalance = user2.balance;
    uint256 totalSupplyBefore = lp.totalSupply();
    vm.expectRevert("unauthorized");
    smartProvider.withdrawCollateralOneCoin(marketParams, withdrawAmount, 1, expectBnbAmt, user2, payable(user2));
    vm.stopPrank();
    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    vm.prank(user2);
    smartProvider.withdrawCollateralOneCoin(marketParams, withdrawAmount, 1, expectBnbAmt, user2, payable(user2));
    (, , uint256 user2CollateralAfter) = moolah.position(marketParams.id(), user2);

    assertEq(user2CollateralAfter, user2Collateral - withdrawAmount);
    assertEq(lpCollateral.balanceOf(address(moolah)), user2CollateralAfter);
    assertEq(lpCollateral.totalSupply(), user2CollateralAfter);

    assertEq(lp.balanceOf(address(smartProvider)), user2CollateralAfter);
    assertEq(lp.totalSupply(), totalSupplyBefore - withdrawAmount);

    assertEq(token0.balanceOf(user2), token0Balance);
    assertEq(user2.balance - bnbBalance, expectBnbAmt);
  }

  function test_peek() public {
    // supply more liquidity to market
    vm.startPrank(userA);
    uint256 usdtAmt = 100_000_000 ether;
    deal(USDT, userA, usdtAmt);
    IERC20(USDT).approve(address(moolah), usdtAmt);
    moolah.supply(marketParams, usdtAmt, 0, userA, bytes(""));
    vm.stopPrank();

    uint256 lpPrice = smartProvider.peek(address(lp));

    // user2 deposit 1000 LP tokens as collateral
    uint256 supplyAmount = 1000 ether;
    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), supplyAmount);
    deal(address(token0), user2, amounts[0]);
    deal(user2, amounts[1]);
    vm.startPrank(user2);
    token0.approve(address(smartProvider), amounts[0]);
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      amounts[1],
      supplyAmount - 10 // minus 10 wei to avoid rounding issue
    );
    // check user2 borrow limit
    (, , uint256 user2Collateral) = moolah.position(marketParams.id(), user2);
    uint256 borrowLimit = (user2Collateral * lpPrice * lltv70) / 1e18 / 1e8;
    moolah.borrow(marketParams, borrowLimit - 100, 0, user2, user2);

    // manipulate lp price by swapping on dex
    uint256 amount0 = 50_000 ether;
    deal(address(token0), user2, amount0);
    token0.approve(address(dex), amount0);
    uint256 amount1BalBefore = user2.balance;
    dex.exchange(0, 1, amount0, 0);
    uint256 amount1BalAfter = user2.balance;

    uint256 lpPrice2 = smartProvider.peek(address(lp));
    // User2 can borrow more
    (, , user2Collateral) = moolah.position(marketParams.id(), user2);
    uint256 newBorrowLimit = (user2Collateral * lpPrice2 * lltv70) / 1e18 / 1e8;
    moolah.borrow(marketParams, newBorrowLimit - borrowLimit, 0, user2, user2);

    // User2 restore pool reserve by swapping back
    uint256 amount1 = amount1BalAfter - amount1BalBefore;
    deal(user2, amount1);
    dex.exchange{ value: amount1 }(1, 0, amount1, 0);
    uint256 lpPrice3 = smartProvider.peek(address(lp));

    // check user2 borrow limit after restore
    (, uint256 borrowedShares, ) = moolah.position(marketParams.id(), user2);
    uint256 borrowLimitAfter = (user2Collateral * lpPrice3 * lltv70) / 1e18 / 1e8;
    (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = moolah.market(marketParams.id());

    uint256 debt = borrowedShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    assertLe(debt, borrowLimitAfter);
    vm.stopPrank();
  }

  function test_redeemLpCollateral() public {
    test_supplyDexLp();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    uint256 redeemAmount = 500 ether;
    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), redeemAmount);
    uint256 amount0Before = token0.balanceOf(user2);
    uint256 amount1Before = user2.balance;

    vm.startPrank(user2);
    vm.expectRevert();
    smartProvider.redeemLpCollateral(redeemAmount, amounts[0], amounts[1]);
    vm.stopPrank();

    vm.prank(address(smartProvider));
    lpCollateral.mint(user2, redeemAmount);
    uint256 lpBalanceBefore = lp.balanceOf(address(smartProvider));
    uint256 lpCollateralBalanceBefore = lpCollateral.balanceOf(address(smartProvider));
    vm.startPrank(user2);
    smartProvider.redeemLpCollateral(redeemAmount, amounts[0], amounts[1]);
    vm.stopPrank();

    uint256 lpBalanceAfter = lp.balanceOf(address(smartProvider));
    uint256 lpCollateralBalanceAfter = lpCollateral.balanceOf(address(smartProvider));

    assertEq(lpBalanceBefore - lpBalanceAfter, redeemAmount);
    assertEq(lpCollateralBalanceBefore, 0);
    assertEq(lpCollateralBalanceAfter, 0);
    assertGe(token0.balanceOf(user2), amounts[0] + amount0Before);
    assertGe(user2.balance, amounts[1] + amount1Before);
  }

  function test_flashloan_token_blacklist() public {
    vm.startPrank(manager);
    moolah.setFlashLoanTokenBlacklist(address(lpCollateral), true);
    assertTrue(moolah.flashLoanTokenBlacklist(address(lpCollateral)));
    vm.stopPrank();

    vm.prank(user2);
    vm.expectRevert("token blacklisted");
    moolah.flashLoan(address(lpCollateral), 100 ether, "");
  }
}

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

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

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
      abi.encodeWithSelector(
        smartProvider.initialize.selector,
        admin,
        manager,
        address(dex),
        address(dexInfo),
        multiOracle
      )
    );
    smartProvider = SmartProvider(payable(address(smartProviderProxy)));

    // set minter for lp collateral
    lpCollateral.setMinter(address(smartProvider));
    assertEq(lpCollateral.MOOLAH(), address(moolah));
    assertEq(lpCollateral.minter(), address(smartProvider));

    // create market
    createMarket();
  }

  function deployDexBnb() public {
    dexInfo = new StableSwapPoolInfo();
    StableSwapFactory factoryImpl = new StableSwapFactory();
    ERC1967Proxy factoryProxy = new ERC1967Proxy(
      address(factoryImpl),
      abi.encodeWithSelector(factoryImpl.initialize.selector, admin)
    );
    factory = StableSwapFactory(address(factoryProxy));

    assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));

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
    address poolImpl = address(new StableSwapPool());
    vm.startPrank(admin);
    factory.setImpls(lpImpl, poolImpl);
    assertEq(factory.lpImpl(), lpImpl);
    assertEq(factory.swapImpl(), poolImpl);

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
    console.log("User A added liquidity");

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

  function test_supplyCollateral_perfect() public {
    // user2 supply 1000 LP tokens as collateral
    uint256 supplyAmount = 1000 ether;

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), supplyAmount);

    deal(address(token0), user2, amounts[0]);
    deal(user2, amounts[1]);

    vm.startPrank(user2);
    token0.approve(address(smartProvider), amounts[0]);
    vm.expectRevert("invalid value or amounts");
    smartProvider.supplyCollateral(marketParams, user2, amounts[0], amounts[1], supplyAmount, bytes(""));
    vm.expectRevert("invalid value or amounts");
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      0, // invalid amount
      supplyAmount,
      bytes("")
    );

    vm.expectRevert("slippage too high");
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      amounts[1],
      supplyAmount, // revert on exact amount due to rounding issue
      bytes("")
    );

    // succeed
    smartProvider.supplyCollateral{ value: amounts[1] }(
      marketParams,
      user2,
      amounts[0],
      amounts[1],
      supplyAmount - 10, // minus 10 wei to avoid rounding issue
      bytes("")
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

  function test_liquidate() public {
    test_borrow_usdt();
    uint256 borrowAmount = 560000 ether;
    vm.prank(user2);
    moolah.borrow(marketParams, borrowAmount, 0, user2, user2);

    skip(1000000 days); // skip to trigger liquidation

    moolah.accrueInterest(marketParams);

    bool isHealthy = moolah.isHealthy(marketParams, marketParams.id(), user2);
    assertTrue(!isHealthy);
    //uint256 supplyShares, uint128 borrowShares, uint128 collateral
    (uint256 supplyShares, uint256 user2Debt, uint256 user2Collateral) = moolah.position(marketParams.id(), user2);

    vm.startPrank(bot);
    deal(USDT, bot, user2Debt + 1000 ether);
    IERC20(USDT).approve(address(moolah), user2Debt + 1000 ether);

    uint256[2] memory amounts = dexInfo.calc_coins_amount(address(dex), user2Collateral);
    uint256 minAmount0 = (amounts[0] * 99) / 100; // slippage 1%
    uint256 minAmount1 = (amounts[1] * 99) / 100; // slippage 1%
    bytes memory payload = abi.encode(minAmount0, minAmount1);

    vm.expectRevert("not set");
    moolah.liquidate(marketParams, user2, user2Collateral, 0, payload, bytes(""));
    vm.stopPrank();

    vm.prank(manager);
    moolah.addProvider(marketParams.id(), address(smartProvider));
    assertEq(moolah.providers(marketParams.id(), address(lpCollateral)), address(smartProvider));

    uint256 bnbReceive = bot.balance;
    vm.startPrank(bot);
    moolah.liquidate(marketParams, user2, user2Collateral, 0, payload, bytes(""));

    assertEq(lpCollateral.balanceOf(address(moolah)), 0);
    (, user2Debt, user2Collateral) = moolah.position(marketParams.id(), user2);
    assertEq(user2Debt, 0);
    assertEq(user2Collateral, 0);
    assertEq(lp.balanceOf(address(smartProvider)), 0); // all lp redeemed
    assertApproxEqAbs(token0.balanceOf(bot), amounts[0], 2); // allow 2 wei difference due to rounding
    assertApproxEqAbs(bot.balance - bnbReceive, amounts[1], 2); // allow 2 wei difference due to rounding
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
}

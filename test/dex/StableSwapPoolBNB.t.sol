// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { StableSwapPoolInfo } from "../../src/dex/StableSwapPoolInfo.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";
import "../../src/dex/interfaces/IStableSwap.sol";

import { StableSwapFactory } from "../../src/dex/StableSwapFactory.sol";

contract StableSwapPoolBNBTest is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  uint256 constant FEE_DENOMINATOR = 1e10;

  StableSwapFactory factory;

  StableSwapPool pool;
  StableSwapPoolInfo poolInfo;

  StableSwapLP lp; // ss-lp

  ERC20Mock token0;
  address token1 = BNB_ADDRESS;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address deployer1 = makeAddr("deployer1");
  address deployer2 = makeAddr("deployer2");
  address oracle = makeAddr("oracle");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");
  address userC = makeAddr("userC");

  bytes32 constant DEPLOYER = keccak256("DEPLOYER");

  function setUp() public {
    poolInfo = new StableSwapPoolInfo();
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
    assertEq(factory.DEPLOYER(), DEPLOYER);

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
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(8466e7));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, token1), abi.encode(830e8));

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
      oracle
    );
    vm.stopPrank();

    lp = StableSwapLP(_lp);
    pool = StableSwapPool(_pool);

    assertEq(pool.coins(0), address(token0));
    assertEq(pool.coins(1), address(token1));
    assertEq(address(pool.token()), address(lp));

    assertEq(pool.A_PRECISION(), 100);
    assertEq(pool.initial_A(), _A * pool.A_PRECISION());
    assertEq(pool.future_A(), _A * pool.A_PRECISION());
    assertEq(pool.A(), _A);
    assertEq(pool.fee(), _fee);
    assertEq(pool.bnb_gas(), 4029);
    assertEq(pool.admin_fee(), _adminFee);
    assertTrue(pool.support_BNB());
    assertEq(pool.oracle(), oracle);
    assertEq(pool.price0DiffThreshold(), 3e16); // 3% price diff threshold
    assertEq(pool.price1DiffThreshold(), 3e16); // 3% price diff threshold

    assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(pool.hasRole(pool.MANAGER(), manager));
    assertTrue(pool.hasRole(pool.PAUSER(), pauser));

    uint256[2] memory oraclePrices = pool.fetchOraclePrice();
    assertEq(oraclePrices[0], 8466e7 * 1e10); // adjust to 18 decimals
    assertEq(oraclePrices[1], 830e8 * 1e10); // adjust to 18 decimals

    // check precision nomalizers and rates
    assertEq(pool.PRECISION_MUL(0), 1); // slisBnb has 18 decimals
    assertEq(pool.PRECISION_MUL(1), 1); // Bnb has 18 decimals
    assertEq(pool.RATES(0), 1e18);
    assertEq(pool.RATES(1), 1e18);
  }

  function test_seeding() public {
    vm.startPrank(userA);
    assertEq(pool.get_virtual_price(), 0); // virtual price should be 0 before seeding

    // Add liquidity
    uint256 ratio = (8466 * 10 ** 17) / 830; // slisBnb price ratio to BNB
    uint256 amount0 = 100_000 * ratio; // slisBnb amount, based on the price ratio
    uint256 amount1 = 100_000 ether; // Bnb

    // Approve tokens for the pool
    token0.approve(address(pool), amount0);

    uint min_mint_amount = 0;
    pool.add_liquidity{ value: amount1 }([amount0, amount1], min_mint_amount);

    // Check LP balance
    uint256 lpAmount = lp.balanceOf(userA);
    assertEq(lpAmount, 201999990107932736938407);

    assertEq(lp.totalSupply(), 201999990107932736938407); // Total supply of LP tokens

    vm.stopPrank();
    assertEq(pool.get_virtual_price(), 1e18); // virtual price should be 1e18 after seeding
  }

  function test_swap_token0_to_token1_given_dx() public {
    test_seeding();

    uint amountIn = 1 ether; // Amount of token0 to swap

    uint256 amountOut = pool.get_dy(0, 1, amountIn); // expect token1 amount out

    uint256 userBBalance0Before = token0.balanceOf(userB);
    uint256 userBBalance1Before = userB.balance;

    vm.startPrank(userB);
    token0.approve(address(pool), 10000 ether);

    // Should revert because of price diff check
    vm.expectRevert("Price difference for token0 exceeds threshold");
    pool.exchange(0, 1, 100000 ether, 0); // 0: token0, 1: token1, amountIn: amount of token0 to swap, 0: min amount out

    // Should succeed
    pool.exchange(0, 1, 100 ether, 0);
    vm.stopPrank();

    // validate the price after swap
    uint256 oraclePrice0 = IOracle(oracle).peek(address(token0));
    uint256 oraclePrice1 = IOracle(oracle).peek(address(token1));

    uint256 token1PriceAfter = (100 ether * oraclePrice0) / pool.get_dy(0, 1, 100 ether);
    uint256 token0PriceAfter = (100 ether * oraclePrice1) / pool.get_dy(1, 0, 100 ether);

    assertGe(token1PriceAfter, (oraclePrice1 * 97) / 100); // 3% price diff tolerance
    assertLe(token1PriceAfter, (oraclePrice1 * 103) / 100); // 3% price diff tolerance
    assertGe(token0PriceAfter, (oraclePrice0 * 97) / 100); // 3% price diff tolerance
    assertLe(token0PriceAfter, (oraclePrice0 * 103) / 100); // 3% price diff tolerance

    uint256 userBBalance0After = token0.balanceOf(userB);
    uint256 userBBalance1After = userB.balance;
    assertEq(userBBalance0After, userBBalance0Before - 100 ether);
    assertGe(userBBalance1After, userBBalance1Before + amountOut);

    assertGt(pool.get_virtual_price(), 1e18); // virtual price should increase after swap
  }

  function test_swap_token1_to_token0_given_dy() public {
    test_seeding();

    uint256 token0AmtOut = 1 ether; // amount out
    uint256 max_dx = 1.2 ether; // max amount in
    uint256 expect_dx = poolInfo.get_dx(address(pool), 1, 0, token0AmtOut, max_dx); // expect token1 amount in
    assertGe(max_dx, expect_dx);
    (uint256 exFee, uint256 exAdminFee) = poolInfo.get_exchange_fee(address(pool), 1, 0, expect_dx);
    uint256 token0BalanceBefore = token0.balanceOf(userC);
    uint256 token1BalanceBefore = userC.balance;
    uint256 poolReserve0Before = pool.balances(0);
    uint256 poolReserve1Before = pool.balances(1);
    uint256 poolBalance0Before = token0.balanceOf(address(pool));
    uint256 poolBalance1Before = address(pool).balance;
    uint256 adminBalance0Before = pool.admin_balances(0);
    uint256 adminBalance1Before = pool.admin_balances(1);

    vm.startPrank(userC);
    vm.expectRevert("Inconsistent quantity");
    pool.exchange(1, 0, expect_dx, token0AmtOut); // 1: token1, 0: token0
    pool.exchange{ value: expect_dx }(1, 0, expect_dx, token0AmtOut); // 1: token1, 0: token0
    vm.stopPrank();

    assertEq(token0.balanceOf(userC), token0BalanceBefore + token0AmtOut);
    assertEq(userC.balance, token1BalanceBefore - expect_dx);
    assertEq(pool.balances(0), poolReserve0Before - token0AmtOut - exAdminFee);
    assertEq(pool.balances(1), poolReserve1Before + expect_dx);
    assertEq(token0.balanceOf(address(pool)), poolBalance0Before - token0AmtOut);
    assertEq(address(pool).balance, poolBalance1Before + expect_dx);
    assertEq(pool.admin_balances(0), adminBalance0Before + exAdminFee);
    assertEq(pool.admin_balances(1), adminBalance1Before);

    assertGt(pool.get_virtual_price(), 1e18); // virtual price should increase after swap
  }

  function test_add_liquidity() public {
    test_swap_token1_to_token0_given_dy();

    // UserB adds liquidity proportionally
    deal(userB, 10000 ether);
    deal(address(token0), userB, 10000 ether);

    uint256 bnbAmount = 100 ether;
    uint256 token0Amount = poolInfo.calc_amount_i_perfect(address(pool), 1, bnbAmount); // token0 amount based on the reserve ratio

    uint256 userBBalance0Before = token0.balanceOf(userB);
    uint256 userBBalance1Before = userB.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();
    uint256 aminFee0 = pool.admin_balances(0);
    uint256 aminFee1 = pool.admin_balances(1);

    vm.startPrank(userB);
    token0.approve(address(pool), token0Amount);
    uint256[2] memory amounts = [token0Amount, bnbAmount];
    uint256 min_mint_amount = (poolInfo.get_add_liquidity_mint_amount(address(pool), amounts) * 99) / 100; // allow 1% slippage
    (uint256[2] memory swapFee, uint256[2] memory adminFee) = poolInfo.get_add_liquidity_fee(address(pool), amounts);
    assertEq(swapFee[0], 0); // no fee for adding liquidity proportionally
    assertEq(swapFee[1], 0); // no fee for adding liquidity proportionally
    assertEq(adminFee[0], 0);
    assertEq(adminFee[1], 0);
    pool.add_liquidity{ value: bnbAmount }(amounts, min_mint_amount);
    vm.stopPrank();

    uint256 userBBalance0After = token0.balanceOf(userB);
    uint256 userBBalance1After = userB.balance;
    assertEq(userBBalance0After, userBBalance0Before - token0Amount);
    assertEq(userBBalance1After, userBBalance1Before - bnbAmount);
    assertEq(pool.balances(0), token0ReserveBefore + token0Amount);
    assertEq(pool.balances(1), token1ReserveBefore + bnbAmount);
    assertEq(lp.totalSupply(), totalSupply + (lp.balanceOf(userB)));
    assertEq(pool.admin_balances(0), aminFee0); // no admin fee for adding liquidity proportionally
    assertEq(pool.admin_balances(1), aminFee1); // no admin fee for adding liquidity proportionally
    assertGe(lp.balanceOf(userB), min_mint_amount);
  }

  function test_add_liquidity_one_coin() public {
    test_swap_token1_to_token0_given_dy();

    // UserB adds liquidity with token0 only
    uint256 token0Amount = 1000 ether;
    uint256 userBBalance0Before = token0.balanceOf(userB);
    uint256 userBBalance1Before = userB.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();
    uint256 aminFee0 = pool.admin_balances(0);
    uint256 aminFee1 = pool.admin_balances(1);
    uint256 lpBalanceBefore = lp.balanceOf(userB);
    uint256[2] memory amountsBefore = poolInfo.get_coins_amount_of(address(pool), userB);
    assertEq(amountsBefore[0], 0);
    assertEq(amountsBefore[1], 0);
    uint256 virtualPriceBefore = pool.get_virtual_price();

    vm.startPrank(userB);
    token0.approve(address(pool), token0Amount);
    uint256[2] memory amounts = [token0Amount, uint256(0)];
    uint256 min_mint_amount = (poolInfo.get_add_liquidity_mint_amount(address(pool), amounts) * 995) / 1000; // allow 0.5% slippage
    (uint256[2] memory swapFee, uint256[2] memory adminFee) = poolInfo.get_add_liquidity_fee(address(pool), amounts);

    pool.add_liquidity(amounts, min_mint_amount);
    vm.stopPrank();

    uint256 userBBalance0After = token0.balanceOf(userB);
    uint256 userBBalance1After = userB.balance;
    uint256 totalSupplyAfter = lp.totalSupply();
    uint256 lpBalanceMinted = lp.balanceOf(userB) - lpBalanceBefore;
    assertGe(lpBalanceMinted, min_mint_amount);
    assertEq(totalSupplyAfter, totalSupply + lpBalanceMinted);
    assertEq(userBBalance0After, userBBalance0Before - token0Amount);
    assertEq(userBBalance1After, userBBalance1Before);
    assertEq(pool.balances(0), token0ReserveBefore + token0Amount - adminFee[0]);
    assertEq(pool.balances(1), token1ReserveBefore - adminFee[1]);
    assertEq(pool.admin_balances(0), aminFee0 + adminFee[0]);
    assertEq(pool.admin_balances(1), aminFee1 + adminFee[1]);
    assertGt(pool.get_virtual_price(), virtualPriceBefore); // virtual price should increase after liquidity addition with fee

    uint256[2] memory amountsAfter = poolInfo.get_coins_amount_of(address(pool), userB);
    uint256 amountInToken0 = amountsAfter[0] + pool.get_dy(1, 0, amountsAfter[1]); // total value in token0
    assertGe(amountInToken0, (1000 ether * 995) / 1000);
  }

  function test_add_liquidity_imbalance() public {
    test_swap_token1_to_token0_given_dy();

    // UserB adds liquidity imbalanced
    uint256 token0Amount = 1000 ether;
    uint256 token1Amount = 500 ether;
    deal(userB, token1Amount);

    uint256 userBBalance0Before = token0.balanceOf(userB);
    uint256 userBBalance1Before = userB.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();
    uint256 aminFee0 = pool.admin_balances(0);
    uint256 aminFee1 = pool.admin_balances(1);
    uint256 lpBalanceBefore = lp.balanceOf(userB);
    uint256[2] memory amountsBefore = poolInfo.get_coins_amount_of(address(pool), userB);
    assertEq(amountsBefore[0], 0);
    assertEq(amountsBefore[1], 0);

    vm.startPrank(userB);
    token0.approve(address(pool), token0Amount);
    uint256[2] memory amounts = [token0Amount, token1Amount];
    uint256 min_mint_amount = (poolInfo.get_add_liquidity_mint_amount(address(pool), amounts) * 995) / 1000; // allow 0.5% slippage
    (uint256[2] memory swapFee, uint256[2] memory adminFee) = poolInfo.get_add_liquidity_fee(address(pool), amounts);
    pool.add_liquidity{ value: token1Amount }(amounts, min_mint_amount);
    vm.stopPrank();

    uint256 userBBalance0After = token0.balanceOf(userB);
    uint256 userBBalance1After = userB.balance;
    uint256 totalSupplyAfter = lp.totalSupply();
    uint256 lpBalanceMinted = lp.balanceOf(userB) - lpBalanceBefore;
    assertGe(lpBalanceMinted, min_mint_amount);
    assertEq(totalSupplyAfter, totalSupply + lpBalanceMinted);
    assertEq(userBBalance0After, userBBalance0Before - token0Amount);
    assertEq(userBBalance1After, userBBalance1Before - token1Amount);
    assertEq(pool.balances(0), token0ReserveBefore + token0Amount - adminFee[0]);
    assertEq(pool.balances(1), token1ReserveBefore + token1Amount - adminFee[1]);
    assertEq(pool.admin_balances(0), aminFee0 + adminFee[0]);
    assertEq(pool.admin_balances(1), aminFee1 + adminFee[1]);
    assertGt(pool.get_virtual_price(), 1e18); // virtual price should increase after liquidity addition with fee
    uint256[2] memory amountsAfter = poolInfo.get_coins_amount_of(address(pool), userB);
    uint256 amountInToken0 = amountsAfter[0] + pool.get_dy(1, 0, amountsAfter[1]); // total value in token0
    assertGe(amountInToken0, (token0Amount * 995) / 1000);
  }

  function test_remove_liquidity() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity
    uint256[2] memory min_amounts = poolInfo.calc_coins_amount(address(pool), 1 ether);
    lp.approve(address(pool), 1 ether);

    uint256 spotPrice0 = pool.get_dy(1, 0, 1e12); // token0 per token1; use tiny dx
    uint256 spotPrice1 = pool.get_dy(0, 1, 1e12); // token1 per token0

    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();
    pool.remove_liquidity(1 ether, min_amounts);
    uint256 userABalance0After = token0.balanceOf(userA);
    uint256 userABalance1After = userA.balance;

    assertGe(userABalance0After, userABalance0Before + min_amounts[0]);
    assertGe(userABalance1After, userABalance1Before + min_amounts[1]);

    vm.stopPrank();
    // check reserves decreased
    assertEq(pool.balances(0), token0ReserveBefore - (userABalance0After - userABalance0Before));
    assertEq(pool.balances(1), token1ReserveBefore - (userABalance1After - userABalance1Before));
    assertEq(lp.totalSupply(), totalSupply - 1 ether);
    // spot price should not move
    uint256 spotPrice0After = pool.get_dy(1, 0, 1e12); // token0 per token1
    uint256 spotPrice1After = pool.get_dy(0, 1, 1e12); // token1 per token0

    assertApproxEqAbs(spotPrice0After, spotPrice0, 2); // allow 2 wei difference
    assertApproxEqAbs(spotPrice1After, spotPrice1, 2); // allow 2 wei difference

    // virtual price should remain the same after liquidity removal proportionally
    assertEq(pool.get_virtual_price(), 1e18);
  }

  function test_remove_liquidity_one_coin() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity; recieving Bnb only, swap fee are in token1
    (uint256 swapFee, uint256 adminFee) = poolInfo.get_remove_liquidity_one_coin_fee(address(pool), 1 ether, 1);
    uint256 expectBnbAmt = pool.calc_withdraw_one_coin(1 ether, 1);

    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();

    lp.approve(address(pool), 1 ether);
    pool.remove_liquidity_one_coin(1 ether, 1, expectBnbAmt);
    vm.stopPrank();

    uint256 userABalance0After = token0.balanceOf(userA);
    uint256 userABalance1After = userA.balance;
    assertEq(userABalance0After, userABalance0Before); // users balance of token0 unchanged
    assertEq(userABalance1After, userABalance1Before + expectBnbAmt);

    // check fee and reserves
    assertEq(pool.balances(0), token0ReserveBefore); // token0 reserve unchanged
    uint256 deductedBnb = token1ReserveBefore - pool.balances(1);
    assertEq(deductedBnb, expectBnbAmt + adminFee); // admin fee deducted from the reserve
    assertEq(adminFee, (swapFee * pool.admin_fee()) / FEE_DENOMINATOR);
    assertEq(lp.totalSupply(), totalSupply - 1 ether);

    assertGt(pool.get_virtual_price(), 1e18); // virtual price should increase after liquidity removal with fee
  }

  function test_remove_liquidity_imbalance() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity imbalanced
    uint256[2] memory amounts = [uint256(10 ether), uint256(5 ether)]; // withdraw 10 slisBnb and 5 Bnb
    (uint256[2] memory swapFee, uint256[2] memory adminFee) = poolInfo.get_remove_liquidity_imbalance_fee(
      address(pool),
      amounts
    );
    uint256 maxBurnAmount = pool.calc_token_amount(amounts, false);
    maxBurnAmount = maxBurnAmount + (maxBurnAmount * 5) / 1000; // add 0.5% slippage

    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 lpBalanceBefore = lp.balanceOf(userA);
    uint256 totalSupplyBefore = lp.totalSupply();

    lp.approve(address(pool), maxBurnAmount);
    pool.remove_liquidity_imbalance(amounts, maxBurnAmount);
    vm.stopPrank();

    uint256 userAReceivedToken0 = token0.balanceOf(userA) - userABalance0Before;
    uint256 userAReceivedToken1 = userA.balance - userABalance1Before;

    assertGe(userAReceivedToken0, amounts[0] - swapFee[0]);
    assertGe(userAReceivedToken1, amounts[1] - swapFee[1]);

    // check fee and reserves
    uint256 deductedToken0 = token0ReserveBefore - pool.balances(0);
    uint256 deductedToken1 = token1ReserveBefore - pool.balances(1);
    assertEq(deductedToken0, userAReceivedToken0 + (swapFee[0] * pool.admin_fee()) / FEE_DENOMINATOR);
    assertEq(deductedToken1, userAReceivedToken1 + (swapFee[1] * pool.admin_fee()) / FEE_DENOMINATOR);
    assertEq(adminFee[0], (swapFee[0] * pool.admin_fee()) / FEE_DENOMINATOR);
    assertEq(adminFee[1], (swapFee[1] * pool.admin_fee()) / FEE_DENOMINATOR);

    assertLe(lpBalanceBefore - lp.balanceOf(userA), maxBurnAmount);
    assertEq(totalSupplyBefore - lp.totalSupply(), lpBalanceBefore - lp.balanceOf(userA));

    assertGt(pool.get_virtual_price(), 1e18); // virtual price should increase after liquidity removal with fee
  }

  function test_paused() public {
    test_seeding();

    vm.prank(pauser);
    pool.pause();
    assertTrue(pool.paused());

    vm.startPrank(userB);
    token0.approve(address(pool), 10000 ether);

    vm.expectRevert("EnforcedPause()");
    pool.exchange(0, 1, 100 ether, 0);

    deal(userB, 100 ether);

    vm.expectRevert("EnforcedPause()");
    uint256[2] memory amounts = [uint256(1 ether), uint256(1 ether)];
    pool.add_liquidity{ value: 1 ether }(amounts, 0);

    vm.expectRevert("EnforcedPause()");
    pool.remove_liquidity_one_coin(1 ether, 0, 0);

    vm.expectRevert("EnforcedPause()");
    pool.remove_liquidity_imbalance(amounts, 0);
    vm.stopPrank();

    vm.startPrank(userA);
    // remove liquidity should work when paused
    lp.approve(address(pool), 1 ether);
    uint256[2] memory min_amounts = [uint256(0), uint256(0)];
    pool.remove_liquidity(1 ether, min_amounts);
    vm.stopPrank();
  }

  function test_changeOracle() public {
    address newOracle = makeAddr("newOracle");
    vm.mockCall(newOracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(8466e7));
    vm.mockCall(newOracle, abi.encodeWithSelector(IOracle.peek.selector, token1), abi.encode(830e8));
    vm.prank(manager);
    pool.changeOracle(newOracle);
    assertEq(pool.oracle(), newOracle);
  }
}

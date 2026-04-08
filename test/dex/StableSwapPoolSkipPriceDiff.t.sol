// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";
import "../../src/dex/interfaces/IStableSwap.sol";
import { StableSwapFactory } from "../../src/dex/StableSwapFactory.sol";

contract StableSwapPoolSkipPriceDiffTest is Test {
  StableSwapFactory factory;
  StableSwapPool pool;
  StableSwapLP lp;
  ERC20Mock token0;
  ERC20Mock token1;

  // coin0/coin1 = pool.coins(0)/pool.coins(1) after factory sort
  ERC20Mock coin0;
  ERC20Mock coin1;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address deployer = makeAddr("deployer");
  address oracle = makeAddr("oracle");
  address userA = makeAddr("userA");
  address userB = makeAddr("userB");

  function setUp() public {
    address[] memory deployers = new address[](1);
    deployers[0] = deployer;
    StableSwapFactory factoryImpl = new StableSwapFactory();
    ERC1967Proxy factoryProxy = new ERC1967Proxy(
      address(factoryImpl),
      abi.encodeWithSelector(factoryImpl.initialize.selector, admin, deployers)
    );
    factory = StableSwapFactory(address(factoryProxy));

    token0 = new ERC20Mock();
    token1 = new ERC20Mock();

    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(100000e8));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token1)), abi.encode(100000e8));

    address lpImpl = address(new StableSwapLP());
    address poolImpl = address(new StableSwapPool(address(factory)));
    vm.startPrank(admin);
    factory.setLpImpl(lpImpl);
    factory.setSwapImpl(poolImpl);
    vm.stopPrank();

    vm.prank(deployer);
    (address _lp, address _pool) = factory.createSwapPair(
      address(token0),
      address(token1),
      "StableSwap LP Token",
      "ss-LP",
      1000,
      1e8,
      5e9,
      admin,
      manager,
      pauser,
      oracle
    );
    lp = StableSwapLP(_lp);
    pool = StableSwapPool(_pool);

    // Factory sorts tokens; resolve actual coin order
    coin0 = ERC20Mock(pool.coins(0));
    coin1 = ERC20Mock(pool.coins(1));

    // Seed pool with liquidity
    token0.setBalance(userA, 10000 ether);
    token1.setBalance(userA, 10000 ether);
    vm.startPrank(userA);
    token0.approve(address(pool), 1000 ether);
    token1.approve(address(pool), 1000 ether);
    pool.add_liquidity([uint256(1000 ether), uint256(1000 ether)], 0);
    vm.stopPrank();

    // Fund userB for swaps
    token0.setBalance(userB, 10000 ether);
    token1.setBalance(userB, 10000 ether);
  }

  function test_setSkipPriceDiff_onlyManager() public {
    assertFalse(pool.skipPriceDiff());

    vm.prank(userA);
    vm.expectRevert();
    pool.setSkipPriceDiff(true);

    vm.prank(manager);
    vm.expectEmit(address(pool));
    emit IStableSwap.SetSkipPriceDiff(true);
    pool.setSkipPriceDiff(true);
    assertTrue(pool.skipPriceDiff());
  }

  function test_exchange_largeSwap_revertsWithoutSkip_succeedsWithSkip() public {
    // Without skip: large swap triggers price diff revert
    vm.startPrank(userB);
    coin0.approve(address(pool), type(uint256).max);
    vm.expectRevert("Price difference for token0 exceeds threshold");
    pool.exchange(0, 1, 900 ether, 0);
    vm.stopPrank();

    // Enable skip
    vm.prank(manager);
    pool.setSkipPriceDiff(true);

    // With skip: same swap succeeds
    uint256 dy = pool.get_dy(0, 1, 900 ether);
    vm.prank(userB);
    pool.exchange(0, 1, 900 ether, 0);
    assertEq(coin1.balanceOf(userB), 10000 ether + dy);
  }

  function test_reEnableCheck_revertsAgain() public {
    vm.prank(manager);
    pool.setSkipPriceDiff(true);

    // Large swap succeeds — pool becomes imbalanced
    vm.startPrank(userB);
    coin0.approve(address(pool), type(uint256).max);
    pool.exchange(0, 1, 900 ether, 0);
    vm.stopPrank();

    // Re-enable check
    vm.prank(manager);
    pool.setSkipPriceDiff(false);

    // Imbalanced pool now reverts again
    vm.prank(userB);
    vm.expectRevert();
    pool.exchange(0, 1, 100 ether, 0);
  }
}

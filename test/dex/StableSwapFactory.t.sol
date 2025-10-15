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

contract StableSwapFactoryTest is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  ERC20Mock token0;
  address token1 = BNB_ADDRESS;
  address oracle = makeAddr("oracle");
  address admin = makeAddr("admin");
  address deployer1 = makeAddr("deployer1");
  address deployer2 = makeAddr("deployer2");

  StableSwapFactory factory;

  bytes32 constant DEPLOYER = keccak256("DEPLOYER");
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

  function setUp() public {
    address[] memory deployers = new address[](2);
    deployers[0] = deployer1;
    deployers[1] = deployer2;
    StableSwapFactory factoryImpl = new StableSwapFactory();
    ERC1967Proxy factoryProxy = new ERC1967Proxy(
      address(factoryImpl),
      abi.encodeWithSelector(factoryImpl.initialize.selector, admin, deployers)
    );
    factory = StableSwapFactory(address(factoryProxy));
    token0 = new ERC20Mock();

    assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, admin));
    assertTrue(factory.hasRole(DEPLOYER, deployer1));
    assertTrue(factory.hasRole(DEPLOYER, deployer2));
  }

  function test_createSwapPair() public {
    // mock oracle calls; token0 (slisBnb) price = $846.6; token1 (BNB) price = $830, rate = 1.02
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(8466e7));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, token1), abi.encode(830e8));

    vm.startPrank(admin);
    address lpImpl = address(new StableSwapLP());
    address swapImpl = address(new StableSwapPool(address(factory)));
    factory.setImpls(lpImpl, swapImpl);
    vm.stopPrank();

    vm.startPrank(deployer1);
    // create 1st pool
    factory.createSwapPair(address(token0), token1, "LPToken", "LPT", 30, 1000000, 500000, admin, admin, admin, oracle);

    (address t0, address t1) = factory.sortTokens(address(token0), token1);
    (address swapContract, address tokenA, address tokenB, address lp) = factory.stableSwapPairInfo(t0, t1, 0);

    assertEq(tokenA, t0);
    assertEq(tokenB, t1);
    assertEq(swapContract, factory.swapPairContract(0));
    assertEq(factory.pairLength(), 1);

    StableSwapFactory.StableSwapPairInfo[] memory pairs = factory.getPairInfo(tokenA, tokenB);
    assertEq(pairs.length, 1);
    assertEq(pairs[0].swapContract, swapContract);
    assertEq(pairs[0].token0, tokenA);
    assertEq(pairs[0].token1, tokenB);
    assertEq(pairs[0].LPContract, lp);

    // create 2nd pool with same tokens
    factory.createSwapPair(
      address(token0),
      token1,
      "LPToken2",
      "LPT2",
      30,
      1000000,
      500000,
      admin,
      admin,
      admin,
      oracle
    );
    (address swapContract2, address tokenA2, address tokenB2, address lp2) = factory.stableSwapPairInfo(t0, t1, 1);
    assertEq(tokenA2, t0);
    assertEq(tokenB2, t1);
    assertEq(swapContract2, factory.swapPairContract(1));
    assertEq(factory.pairLength(), 2);

    StableSwapFactory.StableSwapPairInfo[] memory pairs2 = factory.getPairInfo(tokenA2, tokenB2);
    assertEq(pairs2.length, 2);
    assertEq(pairs2[1].swapContract, swapContract2);
    assertEq(pairs2[1].token0, tokenA2);
    assertEq(pairs2[1].token1, tokenB2);
    assertEq(pairs2[1].LPContract, lp2);

    vm.stopPrank();
  }
}

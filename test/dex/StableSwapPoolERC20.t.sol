// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

contract StableSwapPoolERC20Test is Test {
  StableSwapPool pool;

  StableSwapLP lp; // ss-lp

  ERC20Mock token0;
  ERC20Mock token1;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address oracle = makeAddr("oracle");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");
  address userC = makeAddr("userC");

  function setUp() public {
    // Deploy LP token
    StableSwapLP lpImpl = new StableSwapLP();
    ERC1967Proxy lpProxy = new ERC1967Proxy(address(lpImpl), abi.encodeWithSelector(lpImpl.initialize.selector));
    lp = StableSwapLP(address(lpProxy));

    token0 = new ERC20Mock();
    token1 = new ERC20Mock();

    token0.setBalance(userA, 10000 ether);
    token1.setBalance(userA, 10000 ether);

    token0.setBalance(userB, 10000 ether);
    token1.setBalance(userC, 10000 ether);

    // initialize parameters
    address[2] memory tokens;
    tokens[0] = address(token0);
    tokens[1] = address(token1);

    uint _A = 1000; // Amplification coefficient
    uint _fee = 1e8; // 1%; swap fee
    uint _adminFee = 5e9; // 50% swap fee goes to admin

    // mock oracle calls; token0 price = $100_000; token1 price = $100_000
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(100000e8));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token1)), abi.encode(100000e8));

    StableSwapPool impl = new StableSwapPool();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        tokens,
        _A,
        _fee,
        _adminFee,
        admin,
        manager,
        pauser,
        address(lp),
        oracle
      )
    );

    pool = StableSwapPool(address(proxy));
    lp.setMinter(address(pool));

    assertEq(pool.coins(0), address(token0));
    assertEq(pool.coins(1), address(token1));
    assertEq(address(pool.token()), address(lp));

    assertEq(pool.initial_A(), _A);
    assertEq(pool.future_A(), _A);
    assertEq(pool.fee(), _fee);
    assertEq(pool.admin_fee(), _adminFee);
    assertTrue(!pool.support_BNB());
    assertEq(pool.oracle(), oracle);
    assertEq(pool.price0DiffThreshold(), 3e16); // 3% price diff threshold
    assertEq(pool.price1DiffThreshold(), 3e16); // 3% price diff threshold

    assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(pool.hasRole(pool.MANAGER(), manager));
    assertTrue(pool.hasRole(pool.PAUSER(), pauser));
  }

  function test_addLiquidity() public {
    vm.startPrank(userA);

    // Approve tokens for the pool
    token0.approve(address(pool), 1000 ether);
    token1.approve(address(pool), 1000 ether);

    // Add liquidity
    uint256 amount0 = 1000 ether;
    uint256 amount1 = 1000 ether;

    uint min_mint_amount = 0;
    pool.add_liquidity([amount0, amount1], min_mint_amount);
    console.log("User A added liquidity");

    // Check LP balance
    uint256 lpAmount = lp.balanceOf(userA);
    assertEq(lpAmount, 2000 ether); // 2000 LP tokens minted (1:1 ratio for simplicity)

    assertEq(lp.totalSupply(), 2000 ether); // Total supply of LP tokens

    vm.stopPrank();
  }

  function test_swap_token0_to_token1() public {
    test_addLiquidity();

    uint amountIn = 1 ether; // Amount of token0 to swap

    uint256 amountOut = pool.get_dy(0, 1, amountIn); // expect token1 amount out
    console.log("Amount out for token0 to token1 swap:", amountOut);

    vm.startPrank(userB);
    token0.approve(address(pool), 1000 ether);

    // Should revert because of price diff check
    vm.expectRevert("Price difference for token0 exceeds threshold");
    pool.exchange(0, 1, 1000 ether, 0); // 0: token0, 1: token1, amountIn: amount of token0 to swap, 0: min amount out

    // Should succeed
    pool.exchange(0, 1, 10 ether, 0);
    console.log("User B swapped token0 to token1");
  }
}

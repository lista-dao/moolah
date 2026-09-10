// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapInventoryLib } from "../../src/provider/libraries/SwapInventoryLib.sol";

/// @dev Minimal ERC-20 sufficient for SafeERC20.forceApprove + transfer/transferFrom.
contract MiniERC20 {
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  function mint(address to, uint256 a) external {
    balanceOf[to] += a;
  }

  function approve(address s, uint256 a) external returns (bool) {
    allowance[msg.sender][s] = a;
    return true;
  }

  function transfer(address to, uint256 a) external returns (bool) {
    balanceOf[msg.sender] -= a;
    balanceOf[to] += a;
    return true;
  }

  function transferFrom(address f, address to, uint256 a) external returns (bool) {
    allowance[f][msg.sender] -= a;
    balanceOf[f] -= a;
    balanceOf[to] += a;
    return true;
  }
}

/// @dev A venue that pulls tokenIn, pays tokenOut, AND forwards 1 wei of native to the caller — the
///      Velodrome-style "sweeps its native balance" behaviour an attacker can seed with a dust donation.
contract NativeDonatingVenue {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    MiniERC20(tokenOut).transfer(msg.sender, amountOut);
    (bool ok, ) = msg.sender.call{ value: 1 }("");
    require(ok, "native fwd failed");
  }

  receive() external payable {}
}

/// @dev Harness: an external library call compiles to DELEGATECALL, so inside SwapInventoryLib.swap
///      `address(this)` is this harness (holds tokens, grants allowances, receives native).
contract SwapLibHarness {
  function doSwap(
    address swapPair,
    address token0,
    address token1,
    bool sellToken0,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes memory swapData,
    uint256 total0,
    uint256 total1,
    address wrappedNative,
    bool nativeIn
  ) external returns (uint256, uint256) {
    return
      SwapInventoryLib.swap(
        swapPair,
        token0,
        token1,
        sellToken0,
        amountIn,
        amountOutMin,
        swapData,
        total0,
        total1,
        wrappedNative,
        nativeIn
      );
  }

  receive() external payable {}
}

/// @notice Counter-test for the SwapInventoryLib native-handling fix: when NEITHER swap leg is the
///         wrapped-native token, a venue that forwards stray native must NOT brick the conversion. The
///         live LST pairs always include the wrapped-native leg, so this path is only reachable for a
///         future non-native pair — exercised here against the library directly.
contract SwapInventoryLibNativeTest is Test {
  SwapLibHarness harness;
  NativeDonatingVenue venue;
  MiniERC20 tokenIn;
  MiniERC20 tokenOut;
  address constant WRAPPED_NATIVE = address(0xdEaD); // dummy: NOT either token

  function setUp() public {
    harness = new SwapLibHarness();
    venue = new NativeDonatingVenue();
    tokenIn = new MiniERC20();
    tokenOut = new MiniERC20();

    tokenIn.mint(address(harness), 100 ether); // the position's token0 inventory
    tokenOut.mint(address(venue), 100 ether); // venue pays out token1
    vm.deal(address(venue), 1); // venue has 1 wei native to forward
  }

  function test_swap_ignoresStrayNativeWhenNeitherLegIsWrappedNative() public {
    uint256 amountIn = 10 ether;
    uint256 amountOut = 9 ether;
    bytes memory swapData = abi.encodeWithSelector(
      NativeDonatingVenue.swap.selector,
      address(tokenIn),
      address(tokenOut),
      amountIn,
      amountOut
    );

    // Neither token0 nor token1 is WRAPPED_NATIVE. Pre-fix this reverted UnexpectedNative on the 1-wei
    // donation; post-fix the stray native is ignored and the ERC-20↔ERC-20 swap settles normally.
    (uint256 t0, uint256 t1) = harness.doSwap(
      address(venue),
      address(tokenIn), // token0
      address(tokenOut), // token1
      true, // sellToken0
      amountIn,
      amountOut, // amountOutMin
      swapData,
      100 ether, // total0
      0, // total1
      WRAPPED_NATIVE,
      false // nativeIn
    );

    assertEq(t0, 100 ether - amountIn, "token0 total reduced by spent");
    assertEq(t1, amountOut, "token1 total increased by received");
    assertEq(address(harness).balance, 1, "stray native left untouched (not wrapped, not reverted)");
  }

  /// @notice requested amountIn > held ⇒ fail fast (was: silent cap + opaque allowance revert).
  function test_swap_revertsWhenAmountInExceedsAvail() public {
    uint256 avail = 5 ether; // the position (total0) holds only 5
    uint256 amountIn = 10 ether; // stale swapData requests 10 (> avail)
    bytes memory swapData = abi.encodeWithSelector(
      NativeDonatingVenue.swap.selector,
      address(tokenIn),
      address(tokenOut),
      amountIn,
      uint256(9 ether)
    );

    vm.expectRevert(SwapInventoryLib.InsufficientInventory.selector);
    harness.doSwap(
      address(venue),
      address(tokenIn), // token0
      address(tokenOut), // token1
      true, // sellToken0
      amountIn,
      9 ether, // amountOutMin
      swapData,
      avail, // total0 (available) < amountIn
      0, // total1
      WRAPPED_NATIVE,
      false // nativeIn
    );
  }
}

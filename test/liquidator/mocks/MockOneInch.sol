// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "forge-std/Test.sol";

contract MockOneInch is Test {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin) external {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    deal(tokenOut, address(this), amountOutMin);
    IERC20(tokenOut).transfer(msg.sender, amountOutMin);
  }
}

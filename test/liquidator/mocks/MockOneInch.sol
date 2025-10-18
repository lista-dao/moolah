// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "forge-std/Test.sol";

contract MockOneInch is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin) external payable {
    if (tokenIn == BNB_ADDRESS) {
      require(msg.value == amountIn, "INCORRECT_MSG_VALUE");
    } else {
      require(msg.value == 0, "MSG_VALUE_MUST_BE_0");
      IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    }

    if (tokenOut == BNB_ADDRESS) {
      deal(address(this), amountOutMin);
      (bool success, ) = msg.sender.call{ value: amountOutMin }("");
      require(success, "BNB_TRANSFER_FAILED");
    } else {
      deal(tokenOut, address(this), amountOutMin);
      IERC20(tokenOut).transfer(msg.sender, amountOutMin);
    }
  }
}

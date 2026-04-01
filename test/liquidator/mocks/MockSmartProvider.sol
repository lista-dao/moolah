// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockSmartProvider is Test {
  address public token0;
  address public token1;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function redeemLpCollateral(
    uint256 lpAmount,
    uint256 minToken0Out,
    uint256 minToken1Out
  ) external returns (uint256 token0Out, uint256 token1Out) {
    token0Out = lpAmount / 2;
    token1Out = lpAmount / 2;
    require(token0Out >= minToken0Out, "token0 slippage");
    require(token1Out >= minToken1Out, "token1 slippage");

    deal(token0, address(this), token0Out);
    deal(token1, address(this), token1Out);
    IERC20(token0).transfer(msg.sender, token0Out);
    IERC20(token1).transfer(msg.sender, token1Out);
  }
}

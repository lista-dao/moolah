// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import { Liquidator } from "liquidator/Liquidator.sol";

interface IWBNB {
  function deposit() external payable;
  function withdraw(uint wad) external;
  function transfer(address dst, uint wad) external returns (bool);
  function balanceOf(address owner) external view returns (uint256);
}

contract LiquidatorTest is Test {
  Liquidator liquidator = Liquidator(payable(0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a));
  address manager =  0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  IWBNB wbnb = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_wrapBNB() public {
    vm.startPrank(manager);
    liquidator.withdrawETH(50 ether);

    wbnb.deposit{value: 50 ether}();

    wbnb.transfer(address(liquidator), 50 ether);

    vm.stopPrank();

    console.log("balance", wbnb.balanceOf(address(liquidator)));
  }
}

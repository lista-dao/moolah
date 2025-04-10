// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { LendingRevenueDistributor } from "../../src/revenue/LendingRevenueDistributor.sol";

contract LendingRevenueDistributorTest is Test {
  LendingRevenueDistributor lendingRevenueDistributor;

  address admin = address(0x1);
  address manager = address(0x2);
  address bot = address(0x3);
  address pauser = address(0x4);
  address revenueReceiver = address(0x5);
  address riskFundReceiver = address(0x6);

  ERC20Mock asset;

  function setUp() public {
    asset = new ERC20Mock();

    LendingRevenueDistributor impl = new LendingRevenueDistributor();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        LendingRevenueDistributor.initialize.selector,
        admin,
        manager,
        bot,
        pauser,
        revenueReceiver,
        riskFundReceiver
      )
    );
    lendingRevenueDistributor = LendingRevenueDistributor(payable(address(proxy_)));

    assertEq(lendingRevenueDistributor.hasRole(0x00, admin), true);
    assertEq(lendingRevenueDistributor.hasRole(lendingRevenueDistributor.MANAGER(), manager), true);
    assertEq(lendingRevenueDistributor.hasRole(lendingRevenueDistributor.BOT(), bot), true);
    assertEq(lendingRevenueDistributor.hasRole(lendingRevenueDistributor.PAUSER(), pauser), true);
    assertEq(lendingRevenueDistributor.revenueReceiver(), revenueReceiver);
    assertEq(lendingRevenueDistributor.riskFundReceiver(), riskFundReceiver);
    assertEq(lendingRevenueDistributor.distributePercentage(), 5000);
  }

  function test_distribute() public {
    uint256 amount = 1000;
    asset.setBalance(address(lendingRevenueDistributor), amount);
    uint256 bnbAmount = 2 ether;
    vm.deal(address(lendingRevenueDistributor), bnbAmount);

    address[] memory assets = new address[](2);
    assets[0] = address(asset);
    assets[1] = address(0);

    vm.expectRevert();
    lendingRevenueDistributor.distribute(assets);
    vm.prank(bot);
    lendingRevenueDistributor.distribute(assets);

    assertEq(asset.balanceOf(revenueReceiver), 500);
    assertEq(asset.balanceOf(riskFundReceiver), 500);
    assertEq(address(revenueReceiver).balance, 1 ether);
    assertEq(address(riskFundReceiver).balance, 1 ether);
    assertEq(asset.balanceOf(address(lendingRevenueDistributor)), 0);
    assertEq(address(lendingRevenueDistributor).balance, 0);
  }

  function test_emergencyWithdraw() public {
    uint256 amount = 1000;
    asset.setBalance(address(lendingRevenueDistributor), amount);
    uint256 bnbAmount = 2 ether;
    vm.deal(address(lendingRevenueDistributor), bnbAmount);
    address[] memory assets = new address[](2);
    assets[0] = address(asset);
    assets[1] = address(0);

    vm.expectRevert();
    lendingRevenueDistributor.emergencyWithdraw(assets);
    vm.prank(manager);
    lendingRevenueDistributor.emergencyWithdraw(assets);

    assertEq(asset.balanceOf(manager), amount);
    assertEq(asset.balanceOf(address(lendingRevenueDistributor)), 0);
    assertEq(manager.balance, bnbAmount);
    assertEq(address(lendingRevenueDistributor).balance, 0);
  }

  function test_setDistributePercentage() public {
    vm.expectRevert();
    lendingRevenueDistributor.setDistributePercentage(10000);
    vm.prank(manager);
    lendingRevenueDistributor.setDistributePercentage(10000);

    assertEq(lendingRevenueDistributor.distributePercentage(), 10000);
  }

  function test_setRevenueReceiver() public {
    vm.expectRevert();
    lendingRevenueDistributor.setRevenueReceiver(address(0x7));
    vm.prank(manager);
    lendingRevenueDistributor.setRevenueReceiver(address(0x7));

    assertEq(lendingRevenueDistributor.revenueReceiver(), address(0x7));
  }

  function test_setRiskFundReceiver() public {
    vm.expectRevert();
    lendingRevenueDistributor.setRiskFundReceiver(address(0x8));
    vm.prank(manager);
    lendingRevenueDistributor.setRiskFundReceiver(address(0x8));

    assertEq(lendingRevenueDistributor.riskFundReceiver(), address(0x8));
  }

  function test_pause() public {
    vm.expectRevert();
    lendingRevenueDistributor.pause();
    vm.prank(pauser);
    lendingRevenueDistributor.pause();

    assertEq(lendingRevenueDistributor.paused(), true);

    vm.expectRevert();
    deal(address(lendingRevenueDistributor), 1 ether);
    address[] memory assets = new address[](1);
    vm.prank(bot);
    lendingRevenueDistributor.distribute(assets);

    vm.prank(manager);
    lendingRevenueDistributor.unpause();
    assertEq(lendingRevenueDistributor.paused(), false);
    vm.prank(bot);
    lendingRevenueDistributor.distribute(assets);
    assertEq(address(revenueReceiver).balance, 0.5 ether);
    assertEq(address(riskFundReceiver).balance, 0.5 ether);
  }
}

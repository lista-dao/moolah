// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MarketParams } from "moolah/interfaces/IMoolah.sol";
import "../BaseTest.sol";

contract WhitelistTest is BaseTest {
  using MarketParamsLib for MarketParams;
  address whitelist;
  function setUp() public override {
    super.setUp();
    whitelist = makeAddr("whitelist");
  }

  function testAddWhitelist() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);
    moolah.addLiquidationWhitelist(id, whitelist);
    assertEq(moolah.getLiquidationWhitelist(id).length, 1, "whitelist length");
    assertTrue(moolah.isLiquidationWhitelist(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.addLiquidationWhitelist(id, whitelist);

    vm.stopPrank();
  }

  function testRemoveWhitelist() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.NOT_SET));
    moolah.removeLiquidationWhitelist(id, whitelist);

    moolah.addLiquidationWhitelist(id, whitelist);
    assertEq(moolah.getLiquidationWhitelist(id).length, 1, "whitelist length");
    assertTrue(moolah.isLiquidationWhitelist(id, whitelist), "whitelist");

    moolah.removeLiquidationWhitelist(id, whitelist);
    assertEq(moolah.getLiquidationWhitelist(id).length, 0, "whitelist length");
    assertFalse(moolah.isLiquidationWhitelist(id, whitelist), "whitelist");
    vm.stopPrank();
  }

  function testNotWhiteListLiquidate() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);

    moolah.addLiquidationWhitelist(id, whitelist);
    assertEq(moolah.getLiquidationWhitelist(id).length, 1, "whitelist length");
    assertTrue(moolah.isLiquidationWhitelist(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.NOT_LIQUIDATION_WHITELIST));
    moolah.liquidate(marketParams, BORROWER, 0, 0, "");

    vm.stopPrank();
  }

  function testAddAlphaWhiteList() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);
    moolah.addWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 1, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.addWhiteList(id, whitelist);

    vm.stopPrank();
  }

  function testRemoveAlphaWhiteList() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.NOT_SET));
    moolah.removeWhiteList(id, whitelist);

    moolah.addWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 1, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");

    moolah.removeWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 0, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");
    vm.stopPrank();
  }

  function testNotWhiteListBorrow() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);

    moolah.addWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 1, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.NOT_WHITELIST));
    moolah.borrow(marketParams, 10 ether, 0, BORROWER, BORROWER);

    vm.stopPrank();
  }

  function testNotWhiteListSupply() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);

    moolah.addWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 1, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.NOT_WHITELIST));
    moolah.supply(marketParams, 10 ether, 0, BORROWER, "");

    vm.stopPrank();
  }

  function testNotWhiteListSupplyCollateral() public {
    Id id = marketParams.id();
    vm.startPrank(OWNER);

    moolah.addWhiteList(id, whitelist);
    assertEq(moolah.getWhiteList(id).length, 1, "whitelist length");
    assertTrue(moolah.isWhiteList(id, whitelist), "whitelist");

    vm.expectRevert(bytes(ErrorsLib.NOT_WHITELIST));
    moolah.supplyCollateral(marketParams, 10 ether, SUPPLIER, "");

    vm.stopPrank();
  }

  function testWhiteListOperation() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    Id id = marketParams.id();
    vm.startPrank(OWNER);
    moolah.addWhiteList(id, SUPPLIER);
    moolah.addWhiteList(id, BORROWER);
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 100 ether, BORROWER, "");
    moolah.borrow(marketParams, 80 ether, 0, BORROWER, BORROWER);
    moolah.repay(marketParams, 80 ether, 0, BORROWER, "");
    vm.stopPrank();
  }
}

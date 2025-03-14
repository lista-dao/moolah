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
}

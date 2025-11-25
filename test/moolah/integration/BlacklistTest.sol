// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MarketParams } from "moolah/interfaces/IMoolah.sol";
import "../BaseTest.sol";

contract BlacklistTest is BaseTest {
  using MarketParamsLib for MarketParams;
  address blacklist;
  function setUp() public override {
    super.setUp();
    blacklist = makeAddr("blacklist");
  }

  function testSetBlacklist() public {
    vm.startPrank(OWNER);
    moolah.setVaultBlacklist(blacklist, true);
    assertTrue(moolah.vaultBlacklist(blacklist), "blacklist set");

    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.setVaultBlacklist(blacklist, true);

    moolah.setVaultBlacklist(blacklist, false);
    assertFalse(moolah.vaultBlacklist(blacklist), "blacklist set");

    vm.stopPrank();
  }

  function testBlackListSupply() public {
    vm.startPrank(OWNER);
    moolah.setVaultBlacklist(BORROWER, true);
    assertTrue(moolah.vaultBlacklist(BORROWER), "blacklist set");

    vm.expectRevert(bytes(ErrorsLib.BLACKLISTED));
    moolah.supply(marketParams, 10 ether, 0, BORROWER, "");
    vm.stopPrank();
  }

  function testNotBlackListOperation() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    Id id = marketParams.id();

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

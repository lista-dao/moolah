// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./helpers/IntegrationTest.sol";

contract VaultWhiteListTest is IntegrationTest {
  address whitelist;

  function setUp() public override {
    super.setUp();
    whitelist = makeAddr("whitelist");
  }

  function testAddWhitelist() public {
    vm.startPrank(OWNER);
    vault.setWhiteList(whitelist, true);
    assertEq(vault.getWhiteList().length, 1, "whitelist length");
    assertTrue(vault.isWhiteList(whitelist), "whitelist");

    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AlreadySet.selector));
    vault.setWhiteList(whitelist, true);

    vm.stopPrank();
  }

  function testRemoveWhitelist() public {
    vm.startPrank(OWNER);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotSet.selector));
    vault.setWhiteList(whitelist, false);

    vault.setWhiteList(whitelist, true);
    assertEq(vault.getWhiteList().length, 1, "whitelist length");
    assertTrue(vault.isWhiteList(whitelist), "whitelist");

    vault.setWhiteList(whitelist, false);
    assertEq(vault.getWhiteList().length, 0, "whitelist length");
    assertTrue(vault.isWhiteList(whitelist), "whitelist");
    vm.stopPrank();
  }

  function testNotWhiteListDeposit() public {
    vm.startPrank(OWNER);

    vault.setWhiteList(whitelist, true);
    assertEq(vault.getWhiteList().length, 1, "whitelist length");
    assertTrue(vault.isWhiteList(whitelist), "whitelist");

    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotWhiteList.selector));
    vault.deposit(100 ether, SUPPLIER);

    vm.stopPrank();
  }

  function testNotWhiteListMint() public {
    vm.startPrank(OWNER);

    vault.setWhiteList(whitelist, true);
    assertEq(vault.getWhiteList().length, 1, "whitelist length");
    assertTrue(vault.isWhiteList(whitelist), "whitelist");

    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotWhiteList.selector));
    vault.mint(100 ether, SUPPLIER);

    vm.stopPrank();
  }

  function testWhiteListOperation() public {
    loanToken.setBalance(SUPPLIER, 200 ether);

    vm.startPrank(OWNER);
    vault.setWhiteList(SUPPLIER, true);
    assertEq(vault.getWhiteList().length, 1, "whitelist length");
    assertTrue(vault.isWhiteList(SUPPLIER), "whitelist");
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    vault.deposit(100 ether, SUPPLIER);
    vault.mint(100 ether, SUPPLIER);
    vm.stopPrank();
  }
}

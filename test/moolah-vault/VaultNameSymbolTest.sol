// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./helpers/IntegrationTest.sol";

contract VaultNameSymbolTest is IntegrationTest {
  function setUp() public override {
    super.setUp();
  }

  function testDefaultNameAndSymbol() public view {
    assertEq(vault.name(), "Moolah Vault");
    assertEq(vault.symbol(), "MMV");
  }

  function testSetName() public {
    vm.prank(OWNER);
    vault.setName("New Vault Name");
    assertEq(vault.name(), "New Vault Name");
  }

  function testSetSymbol() public {
    vm.prank(OWNER);
    vault.setSymbol("NVS");
    assertEq(vault.symbol(), "NVS");
  }

  function testSetNameFallbackWhenEmpty() public {
    vm.startPrank(OWNER);
    vault.setName("Custom Name");
    assertEq(vault.name(), "Custom Name");

    // Reset to empty string, should fallback to original
    vault.setName("");
    assertEq(vault.name(), "Moolah Vault");
    vm.stopPrank();
  }

  function testSetSymbolFallbackWhenEmpty() public {
    vm.startPrank(OWNER);
    vault.setSymbol("CSM");
    assertEq(vault.symbol(), "CSM");

    // Reset to empty string, should fallback to original
    vault.setSymbol("");
    assertEq(vault.symbol(), "MMV");
    vm.stopPrank();
  }

  function testSetNameAndSymbolTogether() public {
    vm.startPrank(OWNER);
    vault.setName("Gauntlet x Lista U Vault");
    vault.setSymbol("vlisU");
    vm.stopPrank();

    assertEq(vault.name(), "Gauntlet x Lista U Vault");
    assertEq(vault.symbol(), "vlisU");
  }

  function testSetNameRevertsIfNotAdmin() public {
    vm.prank(SUPPLIER);
    vm.expectRevert();
    vault.setName("Unauthorized");
  }

  function testSetSymbolRevertsIfNotAdmin() public {
    vm.prank(SUPPLIER);
    vm.expectRevert();
    vault.setSymbol("UNA");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UtilsLib } from "moolah/libraries/UtilsLib.sol";

import "./helpers/IntegrationTest.sol";

contract UrdTest is IntegrationTest {
  using UtilsLib for uint256;

  function testSetSkimRecipient(address newSkimRecipient) public {
    vm.assume(newSkimRecipient != SKIM_RECIPIENT);

    vm.expectEmit();
    emit EventsLib.SetSkimRecipient(newSkimRecipient);

    vm.prank(OWNER);
    vault.setSkimRecipient(newSkimRecipient);

    assertEq(vault.skimRecipient(), newSkimRecipient);
  }

  function testAlreadySetSkimRecipient() public {
    vm.prank(OWNER);
    vm.expectRevert(ErrorsLib.AlreadySet.selector);
    vault.setSkimRecipient(SKIM_RECIPIENT);
  }

  function testSetSkimRecipientNotOwner() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), MANAGER_ROLE)
    );
    vault.setSkimRecipient(address(0));
  }

  function testSkimNotLoanToken(uint256 amount) public {
    collateralToken.setBalance(address(vault), amount);

    vm.expectEmit(address(vault));
    emit EventsLib.Skim(address(this), address(collateralToken), amount);
    vault.skim(address(collateralToken));
    uint256 vaultBalanceAfter = collateralToken.balanceOf(address(vault));

    assertEq(vaultBalanceAfter, 0, "vaultBalanceAfter");
    assertEq(collateralToken.balanceOf(SKIM_RECIPIENT), amount, "collateralToken.balanceOf(SKIM_RECIPIENT)");
  }

  function testSkimZeroAddress() public {
    vm.prank(OWNER);
    vault.setSkimRecipient(address(0));

    vm.expectRevert(ErrorsLib.ZeroAddress.selector);
    vault.skim(address(loanToken));
  }
}

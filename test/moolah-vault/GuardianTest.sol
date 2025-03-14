// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./helpers/IntegrationTest.sol";

contract GuardianTest is IntegrationTest {
  using Math for uint256;
  using MathLib for uint256;
  using MarketParamsLib for MarketParams;

  function setUp() public override {
    super.setUp();

    _setGuardian(GUARDIAN_ADDR);
  }

  function testSubmitGuardianNotOwner() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), MANAGER_ROLE)
    );
    vault.grantRole(GUARDIAN_ROLE, GUARDIAN_ADDR);
  }
}

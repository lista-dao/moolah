// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract RoleManagerIntegrationTest is BaseTest {
  using MathLib for uint256;

  function testDeployWithAddressZero() public {
    Moolah moolahImpl = new Moolah();

    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, address(0), address(0), address(0), 0)
    );
  }

  function testGrantRoleWhenNotAdmin(address addressFuzz) public {
    vm.assume(addressFuzz != OWNER);

    vm.prank(addressFuzz);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addressFuzz, DEFAULT_ADMIN_ROLE)
    );
    Moolah(address(moolah)).grantRole(MANAGER, addressFuzz);
  }

  function testGrantRole(address newOwner) public {
    vm.assume(newOwner != OWNER);

    vm.startPrank(OWNER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit IAccessControl.RoleGranted(MANAGER, newOwner, OWNER);
    Moolah(address(moolah)).grantRole(MANAGER, newOwner);
    vm.stopPrank();

    assertTrue(Moolah(address(moolah)).hasRole(MANAGER, newOwner), "owner is not set");
  }

  function testEnableIrmWhenNotOwner(address addressFuzz, address irmFuzz) public {
    vm.assume(addressFuzz != OWNER);
    vm.assume(irmFuzz != address(irm));

    vm.prank(addressFuzz);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addressFuzz, MANAGER)
    );
    moolah.enableIrm(irmFuzz);
  }

  function testEnableIrmAlreadySet() public {
    vm.prank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.enableIrm(address(irm));
  }

  function testEnableIrm(address irmFuzz) public {
    vm.assume(!moolah.isIrmEnabled(irmFuzz));

    vm.prank(OWNER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.EnableIrm(irmFuzz);
    moolah.enableIrm(irmFuzz);

    assertTrue(moolah.isIrmEnabled(irmFuzz), "IRM is not enabled");
  }

  function testEnableLltvWhenNotOwner(address addressFuzz, uint256 lltvFuzz) public {
    vm.assume(addressFuzz != OWNER);
    vm.assume(lltvFuzz != marketParams.lltv);

    vm.prank(addressFuzz);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addressFuzz, MANAGER)
    );
    moolah.enableLltv(lltvFuzz);
  }

  function testEnableLltvAlreadySet() public {
    vm.prank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.enableLltv(marketParams.lltv);
  }

  function testEnableTooHighLltv(uint256 lltv) public {
    lltv = bound(lltv, WAD, type(uint256).max);

    vm.prank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.MAX_LLTV_EXCEEDED));
    moolah.enableLltv(lltv);
  }

  function testEnableLltv(uint256 lltvFuzz) public {
    lltvFuzz = _boundValidLltv(lltvFuzz);

    vm.assume(!moolah.isLltvEnabled(lltvFuzz));

    vm.prank(OWNER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.EnableLltv(lltvFuzz);
    moolah.enableLltv(lltvFuzz);

    assertTrue(moolah.isLltvEnabled(lltvFuzz), "LLTV is not enabled");
  }

  function testSetFeeWhenNotOwner(address addressFuzz, uint256 feeFuzz) public {
    vm.assume(addressFuzz != OWNER);

    vm.prank(addressFuzz);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addressFuzz, MANAGER)
    );
    moolah.setFee(marketParams, feeFuzz);
  }

  function testSetFeeWhenMarketNotCreated(MarketParams memory marketParamsFuzz, uint256 feeFuzz) public {
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.prank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.setFee(marketParamsFuzz, feeFuzz);
  }

  function testSetTooHighFee(uint256 feeFuzz) public {
    feeFuzz = bound(feeFuzz, MAX_FEE + 1, type(uint256).max);

    vm.prank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.MAX_FEE_EXCEEDED));
    moolah.setFee(marketParams, feeFuzz);
  }

  function testSetFee(uint256 feeFuzz) public {
    feeFuzz = bound(feeFuzz, 1, MAX_FEE);

    vm.prank(OWNER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.SetFee(id, feeFuzz);
    moolah.setFee(marketParams, feeFuzz);

    assertEq(moolah.market(id).fee, feeFuzz);
  }

  function testSetFeeRecipientWhenNotOwner(address addressFuzz) public {
    vm.assume(addressFuzz != OWNER);

    vm.prank(addressFuzz);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addressFuzz, MANAGER)
    );
    moolah.setFeeRecipient(addressFuzz);
  }

  function testSetFeeRecipient(address newFeeRecipient) public {
    vm.assume(newFeeRecipient != moolah.feeRecipient());

    vm.prank(OWNER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.SetFeeRecipient(newFeeRecipient);
    moolah.setFeeRecipient(newFeeRecipient);

    assertEq(moolah.feeRecipient(), newFeeRecipient);
  }
}

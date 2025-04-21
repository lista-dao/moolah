// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../BaseTest.sol";
import { MockStakeManager } from "../mocks/MockStakeManager.sol";
import { MockLpToken } from "../mocks/MockLpToken.sol";
import { MoolahSlisBNBProvider } from "moolah/MoolahSlisBNBProvider.sol";

contract MoolahSlisBNBProviderTest is BaseTest {
  MockStakeManager stakeManager;
  MoolahSlisBNBProvider provider;
  MockLpToken lpToken;
  address reserveAddress;
  function setUp() public override {
    super.setUp();

    reserveAddress = makeAddr("RESERVE");

    lpToken = new MockLpToken();

    MockStakeManager stakeManager = new MockStakeManager();
    stakeManager.setExchangeRate(1 ether);


    provider = newMoolahSlisBNBProvider(
      OWNER,
      OWNER,
      address(moolah),
      address(collateralToken),
      address(stakeManager),
      address(lpToken),
      0.03 ether,
      reserveAddress
    );

    vm.startPrank(OWNER);
    moolah.addProvider(address(collateralToken), address(provider));
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    collateralToken.approve(address(provider), type(uint256).max);
    vm.stopPrank();
  }

  function test_supplyCollateral() public {
    collateralToken.setBalance(SUPPLIER, 100 ether);

    vm.startPrank(SUPPLIER);
    vm.expectRevert(bytes("not provider"));
    moolah.supplyCollateral(marketParams, 100 ether, SUPPLIER, "");

    provider.supplyCollateral(marketParams, 100 ether, SUPPLIER, "");
    assertEq(collateralToken.balanceOf(SUPPLIER), 0, "SUPPLIER balance error");
    vm.stopPrank();
  }

  function test_withdrawCollateral() public {
    collateralToken.setBalance(SUPPLIER, 100 ether);

    vm.startPrank(SUPPLIER);
    provider.supplyCollateral(marketParams, 100 ether, SUPPLIER, "");

    vm.expectRevert(bytes("not provider"));
    moolah.withdrawCollateral(marketParams, 100 ether, SUPPLIER, SUPPLIER);
    provider.withdrawCollateral(marketParams, 100 ether, SUPPLIER, SUPPLIER);
    assertEq(collateralToken.balanceOf(SUPPLIER), 100 ether, "SUPPLIER balance error");
    vm.stopPrank();
  }

  function test_addProvider() public {
    address testProvider = makeAddr("PROVIDER");
    address testToken = makeAddr("TOKEN");

    vm.expectRevert(abi.encodeWithSelector(
      IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), provider.MANAGER()
    ));
    moolah.addProvider(testToken, testProvider);

    vm.startPrank(OWNER);
    moolah.addProvider(testToken, testProvider);
    vm.stopPrank();

//    assertEq(testProvider, moolah)
  }

  function test_removeProvider() public {
    address testProvider = makeAddr("PROVIDER");
    address testToken = makeAddr("TOKEN");

    vm.startPrank(OWNER);
    moolah.addProvider(testToken, testProvider);
    vm.stopPrank();


    vm.expectRevert(abi.encodeWithSelector(
      IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), provider.MANAGER()
    ));
    moolah.removeProvider(testToken);

    vm.startPrank(OWNER);
    moolah.removeProvider(testToken);
    vm.stopPrank();
  }

  function newMoolahSlisBNBProvider(
    address admin,
    address manager,
    address _moolah,
    address _token,
    address _stakeManager,
    address _lpToken,
    uint128 _userLpRate,
    address _lpReserveAddress
  ) public returns (MoolahSlisBNBProvider) {
    MoolahSlisBNBProvider providerImpl = new MoolahSlisBNBProvider();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(providerImpl),
      abi.encodeWithSelector(
        providerImpl.initialize.selector,
        admin,
        manager,
        _moolah,
        _token,
        _stakeManager,
        _lpToken,
        _userLpRate,
        _lpReserveAddress
      )
    );
    return MoolahSlisBNBProvider(address(moolahProxy));
  }

}

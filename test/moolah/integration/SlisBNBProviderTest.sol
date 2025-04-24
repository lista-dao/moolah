// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../BaseTest.sol";
import { MockStakeManager } from "../mocks/MockStakeManager.sol";
import { MockLpToken } from "../mocks/MockLpToken.sol";
import { SlisBNBProvider } from "moolah/SlisBNBProvider.sol";

contract SlisBNBProviderTest is BaseTest {
  using MarketParamsLib for MarketParams;

  MockStakeManager stakeManager;
  SlisBNBProvider provider;
  MockLpToken lpToken;
  address MPC;
  function setUp() public override {
    super.setUp();

    MPC = makeAddr("MPC");

    lpToken = new MockLpToken();

    stakeManager = new MockStakeManager();
    stakeManager.setExchangeRate(1 ether);


    provider = newSlisBNBProvider(
      OWNER,
      OWNER,
      address(moolah),
      address(collateralToken),
      address(stakeManager),
      address(lpToken),
      0.997 ether
    );

    vm.startPrank(OWNER);
    moolah.addProvider(address(collateralToken), address(provider));
    provider.addMPCWallet(MPC, type(uint256).max);
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    collateralToken.approve(address(provider), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(BORROWER);
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

    uint256 expectUserLp = 100 ether * 0.997 ether / 1e18;
    uint256 expectReserve = 100 ether - expectUserLp;

    assertEq(provider.userLp(SUPPLIER), expectUserLp, "userLp error");
    assertEq(provider.userReservedLp(SUPPLIER), expectReserve, "userReservedLp error");
    assertEq(provider.totalReservedLp(), expectReserve, "totalReservedLp error");
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

    uint256 expectUserLp = 0;
    uint256 expectReserve = 0;

    assertEq(provider.userLp(SUPPLIER), expectUserLp, "userLp error");
    assertEq(provider.userReservedLp(SUPPLIER), expectReserve, "userReservedLp error");
    assertEq(provider.totalReservedLp(), expectReserve, "totalReservedLp error");
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

    assertEq(testProvider, moolah.providers(testToken), "provider error");
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

    assertEq(address(0), moolah.providers(testToken), "provider error");
  }

  function test_liquidate() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);
    loanToken.setBalance(LIQUIDATOR, 100 ether);

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 ether, 0,SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    provider.supplyCollateral(marketParams, 100 ether, BORROWER, "");
    moolah.borrow(marketParams, 80 ether, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), 1e8 - 1);

    uint256 borrowShares = moolah.position(marketParams.id(), BORROWER).borrowShares;

    vm.startPrank(LIQUIDATOR);
    moolah.liquidate(marketParams, BORROWER, 0, borrowShares, "");
    vm.stopPrank();

    uint256 remainCollateral = moolah.position(marketParams.id(), BORROWER).collateral;
    uint256 expectUserLp = remainCollateral * 0.997 ether / 1e18;
    uint256 expectReserve = remainCollateral - expectUserLp;

    assertEq(provider.userLp(BORROWER), expectUserLp, "userLp error");
    assertEq(provider.userReservedLp(BORROWER), expectReserve, "userReservedLp error");
    assertEq(provider.totalReservedLp(), expectReserve, "totalReservedLp error");

  }

  function newSlisBNBProvider(
    address admin,
    address manager,
    address _moolah,
    address _token,
    address _stakeManager,
    address _lpToken,
    uint128 _userLpRate
  ) public returns (SlisBNBProvider) {
    SlisBNBProvider providerImpl = new SlisBNBProvider(_moolah, _token, _stakeManager, _lpToken);

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(providerImpl),
      abi.encodeWithSelector(
        providerImpl.initialize.selector,
        admin,
        manager,
        _userLpRate
      )
    );
    return SlisBNBProvider(address(moolahProxy));
  }

}

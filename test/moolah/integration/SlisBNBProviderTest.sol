// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../BaseTest.sol";
import { MockStakeManager } from "../mocks/MockStakeManager.sol";
import { MockLpToken } from "../mocks/MockLpToken.sol";
import { SlisBNBProvider } from "../../../src/provider/SlisBNBProvider.sol";
import {MarketParamsLibTest} from "../MarketParamsLibTest.sol";

contract SlisBNBProviderTest is BaseTest {
  using MarketParamsLib for MarketParams;

  MockStakeManager stakeManager;
  SlisBNBProvider provider;
  MockLpToken lpToken;
  address MPC;
  address DELEGATOR;
  function setUp() public override {
    super.setUp();

    MPC = makeAddr("MPC");
    DELEGATOR = makeAddr("DELEGATOR");

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
    moolah.addProvider(marketParams.id(), address(provider));
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
    address testToken = makeAddr("TOKEN");
    address testProvider = address(newSlisBNBProvider(OWNER, OWNER, address(moolah), testToken, address(stakeManager), address(lpToken), 0.997 ether));

    MarketParams memory testMarketParams = MarketParams({
      loanToken: marketParams.loanToken,
      collateralToken: testToken,
      oracle: marketParams.oracle,
      irm: marketParams.irm,
      lltv: marketParams.lltv
    });

    moolah.createMarket(testMarketParams);

    vm.expectRevert(abi.encodeWithSelector(
      IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), provider.MANAGER()
    ));
    moolah.addProvider(testMarketParams.id(), testProvider);

    vm.startPrank(OWNER);
    moolah.addProvider(testMarketParams.id(), testProvider);
    vm.stopPrank();

    assertEq(testProvider, moolah.providers(testMarketParams.id(), testToken), "provider error");
  }

  function test_removeProvider() public {
    address testToken = makeAddr("TOKEN");
    address testProvider = address(newSlisBNBProvider(OWNER, OWNER, address(moolah), testToken, address(stakeManager), address(lpToken), 0.997 ether));

    MarketParams memory testMarketParams = MarketParams({
      loanToken: marketParams.loanToken,
      collateralToken: testToken,
      oracle: marketParams.oracle,
      irm: marketParams.irm,
      lltv: marketParams.lltv
    });

    moolah.createMarket(testMarketParams);

    vm.startPrank(OWNER);
    moolah.addProvider(testMarketParams.id(), testProvider);
    vm.stopPrank();

    vm.expectRevert(abi.encodeWithSelector(
      IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), provider.MANAGER()
    ));
    moolah.removeProvider(testMarketParams.id());

    vm.startPrank(OWNER);
    moolah.removeProvider(testMarketParams.id());
    vm.stopPrank();

    assertEq(address(0), moolah.providers(testMarketParams.id(), testToken), "provider error");
  }

  function test_liquidate() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);
    loanToken.setBalance(LIQUIDATOR, 200 ether);

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

  function test_delegateAllTo() public {
    collateralToken.setBalance(SUPPLIER, 100 ether);

    vm.startPrank(SUPPLIER);
    provider.supplyCollateral(marketParams, 10 ether, SUPPLIER, "");
    assertEq(collateralToken.balanceOf(SUPPLIER), 90 ether, "SUPPLIER balance error");
    assertEq(lpToken.balanceOf(SUPPLIER), 9.97 ether, "SUPPLIER lp balance error");
    provider.delegateAllTo(DELEGATOR);

    assertEq(lpToken.balanceOf(DELEGATOR), 9.97 ether, "DELEGATOR lp balance error");
    provider.supplyCollateral(marketParams, 90 ether, SUPPLIER, "");

    assertEq(lpToken.balanceOf(DELEGATOR), 99.7 ether, "DELEGATOR lp balance error");
    vm.stopPrank();

    uint256 expectUserLp = 100 ether * 0.997 ether / 1e18;
    uint256 expectReserve = 100 ether - expectUserLp;

    assertEq(provider.userLp(SUPPLIER), expectUserLp, "userLp error");
    assertEq(provider.userReservedLp(SUPPLIER), expectReserve, "userReservedLp error");
    assertEq(provider.totalReservedLp(), expectReserve, "totalReservedLp error");

    vm.startPrank(SUPPLIER);
    provider.withdrawCollateral(marketParams, 100 ether, SUPPLIER, SUPPLIER);
    vm.stopPrank();

    assertEq(lpToken.balanceOf(DELEGATOR), 0, "DELEGATOR lp balance error");

    expectUserLp = 0;
    expectReserve = 0;

    assertEq(provider.userLp(SUPPLIER), expectUserLp, "userLp error");
    assertEq(provider.userReservedLp(SUPPLIER), expectReserve, "userReservedLp error");
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

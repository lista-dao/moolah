// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract MinLoanTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  function setUp() public override {
    super.setUp();

    vm.prank(OWNER);
    moolah.setMinLoanValue(1e8 * 15); // 15 usd

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

  }

  function test_supplyMinLoan() public {
    uint8 decimals = loanToken.decimals();
    loanToken.setBalance(SUPPLIER, 10 ** decimals * 100);

    vm.startPrank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.REMAIN_SUPPLY_TOO_LOW));
    moolah.supply(marketParams, 15 * (10**decimals) - 1, 0, SUPPLIER, "");

    moolah.supply(marketParams, 15 * (10**decimals), 0, SUPPLIER, "");
    assertEq(moolah.market(marketParams.id()).totalSupplyAssets, 15 * (10**decimals), "totalSupplyAssets != 15 * 10**decimals");
    vm.stopPrank();

  }

  function test_withdrawMinLoan() public {
    uint8 decimals = loanToken.decimals();
    loanToken.setBalance(SUPPLIER, 10 ** decimals * 100);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 * (10**decimals), 0, SUPPLIER, "");
    assertEq(moolah.market(marketParams.id()).totalSupplyAssets, 100 * (10**decimals), "totalSupplyAssets != 15 * 10**decimals");

    vm.expectRevert(bytes(ErrorsLib.REMAIN_SUPPLY_TOO_LOW));
    moolah.withdraw(marketParams, 85 * (10 ** decimals) + 1, 0, SUPPLIER, SUPPLIER);

    moolah.withdraw(marketParams, 85 * (10 ** decimals), 0, SUPPLIER, SUPPLIER);
    assertEq(moolah.market(marketParams.id()).totalSupplyAssets, 15 * (10**decimals), "totalSupplyAssets != 15 * 10**decimals");

    moolah.withdraw(marketParams, 15 * (10 ** decimals), 0, SUPPLIER, SUPPLIER);
    assertEq(moolah.market(marketParams.id()).totalSupplyAssets, 0, "totalSupplyAssets != 0");
    vm.stopPrank();
  }

  function test_borrowMinLoan() public {
    uint8 decimals = loanToken.decimals();
    loanToken.setBalance(SUPPLIER, 10 ** decimals * 100);
    collateralToken.setBalance(BORROWER, 10 ** decimals * 100);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 * (10**decimals), 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 100 * (10**decimals), BORROWER, "");

    vm.expectRevert(bytes(ErrorsLib.REMAIN_BORROW_TOO_LOW));
    moolah.borrow(marketParams, 15 * (10**decimals) - 1, 0, BORROWER, BORROWER);

    moolah.borrow(marketParams, 15 * (10**decimals), 0, BORROWER, BORROWER);
    assertEq(moolah.market(marketParams.id()).totalBorrowAssets, 15 * (10**decimals), "totalBorrowAssets != 15 * 10**decimals");

    vm.stopPrank();

  }

  function test_repayMinLoan() public {
    uint8 decimals = loanToken.decimals();
    loanToken.setBalance(SUPPLIER, 10 ** decimals * 100);
    collateralToken.setBalance(BORROWER, 10 ** decimals * 100);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 * (10**decimals), 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 100 * (10**decimals), BORROWER, "");

    moolah.borrow(marketParams, 80 * (10**decimals), 0, BORROWER, BORROWER);

    vm.expectRevert(bytes(ErrorsLib.REMAIN_BORROW_TOO_LOW));
    moolah.repay(marketParams, 65 * (10 ** decimals) + 1, 0, BORROWER, "");

    moolah.repay(marketParams, 65 * (10 ** decimals), 0, BORROWER, "");
    assertEq(moolah.market(marketParams.id()).totalBorrowAssets, 15 * (10**decimals), "totalBorrowAssets != 15 * 10**decimals");

    moolah.repay(marketParams, 15 * (10 ** decimals), 0, BORROWER, "");
    assertEq(moolah.market(marketParams.id()).totalBorrowAssets, 0, "totalBorrowAssets != 0");
    vm.stopPrank();
  }

  function test_liquidateMinLoan() public {
    uint8 decimals = loanToken.decimals();
    loanToken.setBalance(SUPPLIER, 10 ** decimals * 100);
    collateralToken.setBalance(BORROWER, 10 ** decimals * 100);
    loanToken.setBalance(LIQUIDATOR, 10 ** decimals * 100);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 * (10**decimals), 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 1875 * (10**(decimals - 2)), BORROWER, "");

    moolah.borrow(marketParams, 15 * (10**decimals), 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), 1e8 - 1);

    uint256 borrowShares = moolah.position(marketParams.id(), BORROWER).borrowShares;

    vm.startPrank(LIQUIDATOR);
    vm.expectRevert(bytes(ErrorsLib.REMAIN_BORROW_TOO_LOW));
    moolah.liquidate(marketParams, BORROWER, 0, 1, "");

    moolah.liquidate(marketParams, BORROWER, 0, borrowShares, "");
    assertEq(moolah.market(marketParams.id()).totalBorrowShares, 0, "totalBorrowShares != 0");
    vm.stopPrank();
  }

  function test_minLoanValue() public {
    oracle.setPrice(address(loanToken), 1e8);

    uint256 assets = moolah.minLoan(marketParams);
    assertEq(assets, 15 * 1e18, "assets != 15 * 1e18");

    oracle.setPrice(address(loanToken), 1e8 * 15);
    assets = moolah.minLoan(marketParams);
    assertEq(assets, 1e18, "assets != 1e18");
  }
}

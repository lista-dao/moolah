// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract WithdrawCollateralIntegrationTest is BaseTest {
  using MathLib for uint256;

  function testWithdrawCollateralMarketNotCreated(MarketParams memory marketParamsFuzz) public {
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.prank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.withdrawCollateral(marketParamsFuzz, 1, SUPPLIER, RECEIVER);
  }

  function testWithdrawCollateralZeroAmount(uint256 amount) public {
    amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

    collateralToken.setBalance(SUPPLIER, amount);

    vm.startPrank(SUPPLIER);
    collateralToken.approve(address(moolah), amount);
    moolah.supplyCollateral(marketParams, amount, SUPPLIER, hex"");

    vm.expectRevert(bytes(ErrorsLib.ZERO_ASSETS));
    moolah.withdrawCollateral(marketParams, 0, SUPPLIER, RECEIVER);
    vm.stopPrank();
  }

  function testWithdrawCollateralToZeroAddress(uint256 amount) public {
    amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

    collateralToken.setBalance(SUPPLIER, amount);

    vm.startPrank(SUPPLIER);
    moolah.supplyCollateral(marketParams, amount, SUPPLIER, hex"");

    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.withdrawCollateral(marketParams, amount, SUPPLIER, address(0));
    vm.stopPrank();
  }

  function testWithdrawCollateralUnauthorized(address attacker, uint256 amount) public {
    vm.assume(attacker != SUPPLIER);
    amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

    collateralToken.setBalance(SUPPLIER, amount);

    vm.prank(SUPPLIER);
    moolah.supplyCollateral(marketParams, amount, SUPPLIER, hex"");

    vm.prank(attacker);
    vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
    moolah.withdrawCollateral(marketParams, amount, SUPPLIER, RECEIVER);
  }

  function testWithdrawCollateralUnhealthyPosition(
    uint256 amountCollateral,
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 priceCollateral
  ) public {
    (amountCollateral, amountBorrowed, priceCollateral) = _boundHealthyPosition(
      amountCollateral,
      amountBorrowed,
      priceCollateral
    );

    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
    _supply(amountSupplied);

    oracle.setPrice(address(collateralToken), priceCollateral);

    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    moolah.withdrawCollateral(marketParams, amountCollateral, BORROWER, BORROWER);
    vm.stopPrank();
  }

  function testWithdrawCollateral(
    uint256 amountCollateral,
    uint256 amountCollateralExcess,
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 priceCollateral
  ) public {
    (amountCollateral, amountBorrowed, priceCollateral) = _boundHealthyPosition(
      amountCollateral,
      amountBorrowed,
      priceCollateral
    );
    vm.assume(amountCollateral < MAX_COLLATERAL_ASSETS);

    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
    _supply(amountSupplied);

    amountCollateralExcess = bound(
      amountCollateralExcess,
      1,
      Math.min(MAX_COLLATERAL_ASSETS - amountCollateral, type(uint256).max / priceCollateral - amountCollateral)
    );

    oracle.setPrice(address(collateralToken), priceCollateral);

    collateralToken.setBalance(BORROWER, amountCollateral + amountCollateralExcess);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral + amountCollateralExcess, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.WithdrawCollateral(id, BORROWER, BORROWER, RECEIVER, amountCollateralExcess);
    moolah.withdrawCollateral(marketParams, amountCollateralExcess, BORROWER, RECEIVER);

    vm.stopPrank();

    assertEq(moolah.position(id, BORROWER).collateral, amountCollateral, "collateral balance");
    assertEq(collateralToken.balanceOf(RECEIVER), amountCollateralExcess, "lender balance");
    assertEq(collateralToken.balanceOf(address(moolah)), amountCollateral, "moolah balance");
  }

  function testWithdrawCollateralOnBehalf(
    uint256 amountCollateral,
    uint256 amountCollateralExcess,
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 priceCollateral
  ) public {
    (amountCollateral, amountBorrowed, priceCollateral) = _boundHealthyPosition(
      amountCollateral,
      amountBorrowed,
      priceCollateral
    );
    vm.assume(amountCollateral < MAX_COLLATERAL_ASSETS);

    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
    _supply(amountSupplied);

    oracle.setPrice(address(collateralToken), priceCollateral);

    amountCollateralExcess = bound(
      amountCollateralExcess,
      1,
      Math.min(MAX_COLLATERAL_ASSETS - amountCollateral, type(uint256).max / priceCollateral - amountCollateral)
    );

    collateralToken.setBalance(ONBEHALF, amountCollateral + amountCollateralExcess);

    vm.startPrank(ONBEHALF);
    moolah.supplyCollateral(marketParams, amountCollateral + amountCollateralExcess, ONBEHALF, hex"");
    // BORROWER is already authorized.
    moolah.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
    vm.stopPrank();

    vm.prank(BORROWER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.WithdrawCollateral(id, BORROWER, ONBEHALF, RECEIVER, amountCollateralExcess);
    moolah.withdrawCollateral(marketParams, amountCollateralExcess, ONBEHALF, RECEIVER);

    assertEq(moolah.position(id, ONBEHALF).collateral, amountCollateral, "collateral balance");
    assertEq(collateralToken.balanceOf(RECEIVER), amountCollateralExcess, "lender balance");
    assertEq(collateralToken.balanceOf(address(moolah)), amountCollateral, "moolah balance");
  }
}

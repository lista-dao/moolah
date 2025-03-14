// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract RepayIntegrationTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;

  function testRepayMarketNotCreated(MarketParams memory marketParamsFuzz) public {
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.repay(marketParamsFuzz, 1, 0, address(this), hex"");
  }

  function testRepayZeroAmount() public {
    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.repay(marketParams, 0, 0, address(this), hex"");
  }

  function testRepayInconsistentInput(uint256 amount, uint256 shares) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);
    shares = bound(shares, 1, MAX_TEST_SHARES);

    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.repay(marketParams, amount, shares, address(this), hex"");
  }

  function testRepayOnBehalfZeroAddress(uint256 input, bool isAmount) public {
    input = bound(input, 1, type(uint256).max);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.repay(marketParams, isAmount ? input : 0, isAmount ? 0 : input, address(0), hex"");
  }

  function testRepayAssets(
    uint256 amountSupplied,
    uint256 amountCollateral,
    uint256 amountBorrowed,
    uint256 amountRepaid,
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

    amountRepaid = bound(amountRepaid, 1, amountBorrowed);
    uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);
    uint256 expectedRepaidShares = amountRepaid.toSharesDown(amountBorrowed, expectedBorrowShares);

    collateralToken.setBalance(ONBEHALF, amountCollateral);
    loanToken.setBalance(REPAYER, amountRepaid);

    vm.startPrank(ONBEHALF);
    moolah.supplyCollateral(marketParams, amountCollateral, ONBEHALF, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, ONBEHALF, RECEIVER);
    vm.stopPrank();

    vm.prank(REPAYER);
    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Repay(id, REPAYER, ONBEHALF, amountRepaid, expectedRepaidShares);
    (uint256 returnAssets, uint256 returnShares) = moolah.repay(marketParams, amountRepaid, 0, ONBEHALF, hex"");

    expectedBorrowShares -= expectedRepaidShares;

    assertEq(returnAssets, amountRepaid, "returned asset amount");
    assertEq(returnShares, expectedRepaidShares, "returned shares amount");
    assertEq(moolah.position(id, ONBEHALF).borrowShares, expectedBorrowShares, "borrow shares");
    assertEq(moolah.market(id).totalBorrowAssets, amountBorrowed - amountRepaid, "total borrow");
    assertEq(moolah.market(id).totalBorrowShares, expectedBorrowShares, "total borrow shares");
    assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "RECEIVER balance");
    assertEq(loanToken.balanceOf(address(moolah)), amountSupplied - amountBorrowed + amountRepaid, "moolah balance");
  }

  function testRepayShares(
    uint256 amountSupplied,
    uint256 amountCollateral,
    uint256 amountBorrowed,
    uint256 sharesRepaid,
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

    uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);
    sharesRepaid = bound(sharesRepaid, 1, expectedBorrowShares);
    uint256 expectedAmountRepaid = sharesRepaid.toAssetsUp(amountBorrowed, expectedBorrowShares);

    collateralToken.setBalance(ONBEHALF, amountCollateral);
    loanToken.setBalance(REPAYER, expectedAmountRepaid);

    vm.startPrank(ONBEHALF);
    moolah.supplyCollateral(marketParams, amountCollateral, ONBEHALF, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, ONBEHALF, RECEIVER);
    vm.stopPrank();

    vm.prank(REPAYER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Repay(id, REPAYER, ONBEHALF, expectedAmountRepaid, sharesRepaid);
    (uint256 returnAssets, uint256 returnShares) = moolah.repay(marketParams, 0, sharesRepaid, ONBEHALF, hex"");

    expectedBorrowShares -= sharesRepaid;

    assertEq(returnAssets, expectedAmountRepaid, "returned asset amount");
    assertEq(returnShares, sharesRepaid, "returned shares amount");
    assertEq(moolah.position(id, ONBEHALF).borrowShares, expectedBorrowShares, "borrow shares");
    assertEq(moolah.market(id).totalBorrowAssets, amountBorrowed - expectedAmountRepaid, "total borrow");
    assertEq(moolah.market(id).totalBorrowShares, expectedBorrowShares, "total borrow shares");
    assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "RECEIVER balance");
    assertEq(
      loanToken.balanceOf(address(moolah)),
      amountSupplied - amountBorrowed + expectedAmountRepaid,
      "moolah balance"
    );
  }

  function testRepayMax(uint256 shares) public {
    shares = bound(shares, MIN_TEST_SHARES, MAX_TEST_SHARES);

    uint256 assets = shares.toAssetsUp(0, 0);

    loanToken.setBalance(address(this), assets);

    moolah.supply(marketParams, 0, shares, SUPPLIER, hex"");

    collateralToken.setBalance(address(this), HIGH_COLLATERAL_AMOUNT);

    moolah.supplyCollateral(marketParams, HIGH_COLLATERAL_AMOUNT, BORROWER, hex"");

    vm.prank(BORROWER);
    moolah.borrow(marketParams, 0, shares, BORROWER, RECEIVER);

    loanToken.setBalance(address(this), assets);

    moolah.repay(marketParams, 0, shares, BORROWER, hex"");
  }
}

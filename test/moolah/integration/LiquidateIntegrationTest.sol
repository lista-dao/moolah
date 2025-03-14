// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract LiquidateIntegrationTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;

  function testLiquidateNotCreatedMarket(MarketParams memory marketParamsFuzz, uint256 lltv) public {
    _setLltv(_boundTestLltv(lltv));
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.liquidate(marketParamsFuzz, address(this), 1, 0, hex"");
  }

  function testLiquidateZeroAmount(uint256 lltv) public {
    _setLltv(_boundTestLltv(lltv));
    vm.prank(BORROWER);

    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.liquidate(marketParams, address(this), 0, 0, hex"");
  }

  function testLiquidateInconsistentInput(uint256 seized, uint256 sharesRepaid) public {
    seized = bound(seized, 1, MAX_TEST_AMOUNT);
    sharesRepaid = bound(sharesRepaid, 1, MAX_TEST_SHARES);

    vm.prank(BORROWER);

    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.liquidate(marketParams, address(this), seized, sharesRepaid, hex"");
  }

  function testLiquidateHealthyPosition(
    uint256 amountCollateral,
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 amountSeized,
    uint256 priceCollateral,
    uint256 lltv
  ) public {
    _setLltv(_boundTestLltv(lltv));
    (amountCollateral, amountBorrowed, priceCollateral) = _boundHealthyPosition(
      amountCollateral,
      amountBorrowed,
      priceCollateral
    );

    amountSupplied = bound(amountSupplied, amountBorrowed, amountBorrowed + MAX_TEST_AMOUNT);
    _supply(amountSupplied);

    amountSeized = bound(amountSeized, 1, amountCollateral);

    oracle.setPrice(address(collateralToken), priceCollateral);

    loanToken.setBalance(LIQUIDATOR, amountBorrowed);
    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    vm.prank(LIQUIDATOR);
    vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
    moolah.liquidate(marketParams, BORROWER, amountSeized, 0, hex"");
  }

  struct LiquidateTestParams {
    uint256 amountCollateral;
    uint256 amountSupplied;
    uint256 amountBorrowed;
    uint256 priceCollateral;
    uint256 lltv;
  }

  function testLiquidateMargin(LiquidateTestParams memory params, uint256 amountSeized, uint256 elapsed) public {
    _setLltv(_boundTestLltv(params.lltv));
    (params.amountCollateral, params.amountBorrowed, params.priceCollateral) = _boundHealthyPosition(
      params.amountCollateral,
      params.amountBorrowed,
      1e36
    );

    elapsed = bound(elapsed, 0, 365 days);

    params.amountSupplied = bound(
      params.amountSupplied,
      params.amountBorrowed,
      params.amountBorrowed + MAX_TEST_AMOUNT
    );
    _supply(params.amountSupplied);

    amountSeized = bound(amountSeized, 1, params.amountCollateral);

    oracle.setPrice(address(collateralToken), params.priceCollateral);

    loanToken.setBalance(LIQUIDATOR, params.amountBorrowed);
    collateralToken.setBalance(BORROWER, params.amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, params.amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, params.amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    // We have to estimate the ratio after borrowing because the borrow rate depends on the utilization.
    uint256 maxRatio = WAD + irm.borrowRate(marketParams, moolah.market(id)).wTaylorCompounded(elapsed);
    // Sanity check: multiply maxBorrow by 2.
    uint256 maxBorrow = _maxBorrow(marketParams, BORROWER).wDivDown(maxRatio);
    // Should not omit too many tests because elapsed is reasonably bounded.
    vm.assume(params.amountBorrowed < maxBorrow);

    vm.warp(block.timestamp + elapsed);

    vm.prank(LIQUIDATOR);
    vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
    moolah.liquidate(marketParams, BORROWER, amountSeized, 0, hex"");
  }

  function testLiquidateSeizedInputNoBadDebtRealized(LiquidateTestParams memory params, uint256 amountSeized) public {
    _setLltv(_boundTestLltv(params.lltv));
    (params.amountCollateral, params.amountBorrowed, params.priceCollateral) = _boundUnhealthyPosition(
      params.amountCollateral,
      params.amountBorrowed,
      params.priceCollateral
    );

    vm.assume(params.amountCollateral > 1);

    params.amountSupplied = bound(
      params.amountSupplied,
      params.amountBorrowed,
      params.amountBorrowed + MAX_TEST_AMOUNT
    );
    _supply(params.amountSupplied);

    collateralToken.setBalance(BORROWER, params.amountCollateral);

    oracle.setPrice(address(collateralToken), type(uint256).max / params.amountCollateral / 1e36);
    oracle.setPrice(address(loanToken), 1);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, params.amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, params.amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), params.priceCollateral);
    oracle.setPrice(address(loanToken), 1e36);

    uint256 borrowShares = moolah.position(id, BORROWER).borrowShares;
    uint256 liquidationIncentiveFactor = _liquidationIncentiveFactor(marketParams.lltv);
    uint256 maxSeized = params.amountBorrowed.wMulDown(liquidationIncentiveFactor).mulDivDown(
      ORACLE_PRICE_SCALE,
      params.priceCollateral
    );
    vm.assume(maxSeized != 0);

    amountSeized = bound(amountSeized, 1, Math.min(maxSeized, params.amountCollateral - 1));

    uint256 expectedRepaid = amountSeized.mulDivUp(params.priceCollateral, ORACLE_PRICE_SCALE).wDivUp(
      liquidationIncentiveFactor
    );
    uint256 expectedRepaidShares = expectedRepaid.toSharesDown(
      moolah.market(id).totalBorrowAssets,
      moolah.market(id).totalBorrowShares
    );

    loanToken.setBalance(LIQUIDATOR, params.amountBorrowed);

    vm.prank(LIQUIDATOR);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Liquidate(id, LIQUIDATOR, BORROWER, expectedRepaid, expectedRepaidShares, amountSeized, 0, 0);
    (uint256 returnSeized, uint256 returnRepaid) = moolah.liquidate(marketParams, BORROWER, amountSeized, 0, hex"");

    uint256 expectedCollateral = params.amountCollateral - amountSeized;
    uint256 expectedBorrowed = params.amountBorrowed - expectedRepaid;
    uint256 expectedBorrowShares = borrowShares - expectedRepaidShares;

    assertEq(returnSeized, amountSeized, "returned seized amount");
    assertEq(returnRepaid, expectedRepaid, "returned asset amount");
    assertEq(moolah.position(id, BORROWER).borrowShares, expectedBorrowShares, "borrow shares");
    assertEq(moolah.market(id).totalBorrowAssets, expectedBorrowed, "total borrow");
    assertEq(moolah.market(id).totalBorrowShares, expectedBorrowShares, "total borrow shares");
    assertEq(moolah.position(id, BORROWER).collateral, expectedCollateral, "collateral");
    assertEq(loanToken.balanceOf(BORROWER), params.amountBorrowed, "borrower balance");
    assertEq(loanToken.balanceOf(LIQUIDATOR), expectedBorrowed, "liquidator balance");
    assertEq(loanToken.balanceOf(address(moolah)), params.amountSupplied - expectedBorrowed, "moolah balance");
    assertEq(collateralToken.balanceOf(address(moolah)), expectedCollateral, "moolah collateral balance");
    assertEq(collateralToken.balanceOf(LIQUIDATOR), amountSeized, "liquidator collateral balance");
  }

  function testLiquidateSharesInputNoBadDebtRealized(LiquidateTestParams memory params, uint256 sharesRepaid) public {
    _setLltv(_boundTestLltv(params.lltv));
    (params.amountCollateral, params.amountBorrowed, params.priceCollateral) = _boundUnhealthyPosition(
      params.amountCollateral,
      params.amountBorrowed,
      params.priceCollateral
    );

    vm.assume(params.amountCollateral >= 1);

    params.amountSupplied = bound(params.amountSupplied, params.amountBorrowed, MAX_TEST_AMOUNT);
    _supply(params.amountSupplied);

    collateralToken.setBalance(BORROWER, params.amountCollateral);

    oracle.setPrice(address(collateralToken), type(uint256).max / params.amountCollateral / 1e36);
    oracle.setPrice(address(loanToken), 1);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, params.amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, params.amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), params.priceCollateral);
    oracle.setPrice(address(loanToken), 1e36);

    uint256 borrowShares = moolah.position(id, BORROWER).borrowShares;
    uint256 liquidationIncentiveFactor = _liquidationIncentiveFactor(marketParams.lltv);
    uint256 maxSharesRepaid = (params.amountCollateral - 1)
      .mulDivDown(params.priceCollateral, ORACLE_PRICE_SCALE)
      .wDivDown(liquidationIncentiveFactor)
      .toSharesDown(moolah.market(id).totalBorrowAssets, moolah.market(id).totalBorrowShares);
    vm.assume(maxSharesRepaid != 0);

    sharesRepaid = bound(sharesRepaid, 1, Math.min(borrowShares, maxSharesRepaid));

    uint256 expectedRepaid = sharesRepaid.toAssetsUp(
      moolah.market(id).totalBorrowAssets,
      moolah.market(id).totalBorrowShares
    );
    uint256 expectedSeized = sharesRepaid
      .toAssetsDown(moolah.market(id).totalBorrowAssets, moolah.market(id).totalBorrowShares)
      .wMulDown(liquidationIncentiveFactor)
      .mulDivDown(ORACLE_PRICE_SCALE, params.priceCollateral);

    loanToken.setBalance(LIQUIDATOR, params.amountBorrowed);

    vm.prank(LIQUIDATOR);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Liquidate(id, LIQUIDATOR, BORROWER, expectedRepaid, sharesRepaid, expectedSeized, 0, 0);
    (uint256 returnSeized, uint256 returnRepaid) = moolah.liquidate(marketParams, BORROWER, 0, sharesRepaid, hex"");

    uint256 expectedCollateral = params.amountCollateral - expectedSeized;
    uint256 expectedBorrowed = params.amountBorrowed - expectedRepaid;
    uint256 expectedBorrowShares = borrowShares - sharesRepaid;

    assertEq(returnSeized, expectedSeized, "returned seized amount");
    assertEq(returnRepaid, expectedRepaid, "returned asset amount");
    assertEq(moolah.position(id, BORROWER).borrowShares, expectedBorrowShares, "borrow shares");
    assertEq(moolah.market(id).totalBorrowAssets, expectedBorrowed, "total borrow");
    assertEq(moolah.market(id).totalBorrowShares, expectedBorrowShares, "total borrow shares");
    assertEq(moolah.position(id, BORROWER).collateral, expectedCollateral, "collateral");
    assertEq(loanToken.balanceOf(BORROWER), params.amountBorrowed, "borrower balance");
    assertEq(loanToken.balanceOf(LIQUIDATOR), expectedBorrowed, "liquidator balance");
    assertEq(loanToken.balanceOf(address(moolah)), params.amountSupplied - expectedBorrowed, "moolah balance");
    assertEq(collateralToken.balanceOf(address(moolah)), expectedCollateral, "moolah collateral balance");
    assertEq(collateralToken.balanceOf(LIQUIDATOR), expectedSeized, "liquidator collateral balance");
  }

  struct LiquidateBadDebtTestParams {
    uint256 liquidationIncentiveFactor;
    uint256 expectedRepaid;
    uint256 expectedRepaidShares;
    uint256 borrowSharesBeforeLiquidation;
    uint256 totalBorrowSharesBeforeLiquidation;
    uint256 totalBorrowBeforeLiquidation;
    uint256 totalSupplyBeforeLiquidation;
    uint256 expectedBadDebt;
  }

  function testLiquidateBadDebtRealized(
    uint256 amountCollateral,
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 priceCollateral,
    uint256 lltv
  ) public {
    _setLltv(_boundTestLltv(lltv));
    LiquidateBadDebtTestParams memory params;

    (amountCollateral, amountBorrowed, priceCollateral) = _boundUnhealthyPosition(
      amountCollateral,
      amountBorrowed,
      priceCollateral
    );

    vm.assume(amountCollateral > 1);

    params.liquidationIncentiveFactor = _liquidationIncentiveFactor(marketParams.lltv);
    params.expectedRepaid = amountCollateral.mulDivUp(priceCollateral, ORACLE_PRICE_SCALE).wDivUp(
      params.liquidationIncentiveFactor
    );

    uint256 minBorrowed = Math.max(params.expectedRepaid, amountBorrowed);
    amountBorrowed = bound(amountBorrowed, minBorrowed, Math.max(minBorrowed, MAX_TEST_AMOUNT));

    amountSupplied = bound(amountSupplied, amountBorrowed, Math.max(amountBorrowed, MAX_TEST_AMOUNT));
    _supply(amountSupplied);

    loanToken.setBalance(LIQUIDATOR, amountBorrowed);
    collateralToken.setBalance(BORROWER, amountCollateral);

    oracle.setPrice(address(collateralToken), type(uint256).max / amountCollateral / 1e36);
    oracle.setPrice(address(loanToken), 1);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), priceCollateral);
    oracle.setPrice(address(loanToken), 1e36);

    params.expectedRepaidShares = params.expectedRepaid.toSharesDown(
      moolah.market(id).totalBorrowAssets,
      moolah.market(id).totalBorrowShares
    );
    params.borrowSharesBeforeLiquidation = moolah.position(id, BORROWER).borrowShares;
    params.totalBorrowSharesBeforeLiquidation = moolah.market(id).totalBorrowShares;
    params.totalBorrowBeforeLiquidation = moolah.market(id).totalBorrowAssets;
    params.totalSupplyBeforeLiquidation = moolah.market(id).totalSupplyAssets;
    params.expectedBadDebt = (params.borrowSharesBeforeLiquidation - params.expectedRepaidShares).toAssetsUp(
      params.totalBorrowBeforeLiquidation - params.expectedRepaid,
      params.totalBorrowSharesBeforeLiquidation - params.expectedRepaidShares
    );

    vm.prank(LIQUIDATOR);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Liquidate(
      id,
      LIQUIDATOR,
      BORROWER,
      params.expectedRepaid,
      params.expectedRepaidShares,
      amountCollateral,
      params.expectedBadDebt,
      params.expectedBadDebt * SharesMathLib.VIRTUAL_SHARES
    );
    (uint256 returnSeized, uint256 returnRepaid) = moolah.liquidate(marketParams, BORROWER, amountCollateral, 0, hex"");

    assertEq(returnSeized, amountCollateral, "returned seized amount");
    assertEq(returnRepaid, params.expectedRepaid, "returned asset amount");
    assertEq(moolah.position(id, BORROWER).collateral, 0, "collateral");
    assertEq(loanToken.balanceOf(BORROWER), amountBorrowed, "borrower balance");
    assertEq(loanToken.balanceOf(LIQUIDATOR), amountBorrowed - params.expectedRepaid, "liquidator balance");
    assertEq(
      loanToken.balanceOf(address(moolah)),
      amountSupplied - amountBorrowed + params.expectedRepaid,
      "moolah balance"
    );
    assertEq(collateralToken.balanceOf(address(moolah)), 0, "moolah collateral balance");
    assertEq(collateralToken.balanceOf(LIQUIDATOR), amountCollateral, "liquidator collateral balance");

    // Bad debt realization.
    assertEq(moolah.position(id, BORROWER).borrowShares, 0, "borrow shares");
    assertEq(moolah.market(id).totalBorrowShares, 0, "total borrow shares");
    assertEq(
      moolah.market(id).totalBorrowAssets,
      params.totalBorrowBeforeLiquidation - params.expectedRepaid - params.expectedBadDebt,
      "total borrow"
    );
    assertEq(
      moolah.market(id).totalSupplyAssets,
      params.totalSupplyBeforeLiquidation - params.expectedBadDebt,
      "total supply"
    );
  }

  function testBadDebtOverTotalBorrowAssets() public {
    uint256 collateralAmount = 10 ether;
    uint256 loanAmount = 1 ether;
    _supply(loanAmount);

    collateralToken.setBalance(BORROWER, collateralAmount);
    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, collateralAmount, BORROWER, hex"");
    moolah.borrow(marketParams, loanAmount, 0, BORROWER, BORROWER);
    // Trick to inflate shares, so that the computed bad debt is greater than the total debt of the market.
    moolah.borrow(marketParams, 0, 1, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), 1e8 / 100);
    oracle.setPrice(address(loanToken), 1e8);

    loanToken.setBalance(LIQUIDATOR, loanAmount);
    vm.prank(LIQUIDATOR);
    moolah.liquidate(marketParams, BORROWER, collateralAmount, 0, hex"");
  }

  function testSeizedAssetsRoundUp() public {
    _setLltv(0.75e18);
    _supply(100e18);

    uint256 amountCollateral = 400;
    uint256 amountBorrowed = 300;
    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE - 0.01e18);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(LIQUIDATOR, amountBorrowed);

    vm.prank(LIQUIDATOR);
    (uint256 seizedAssets, uint256 repaidAssets) = moolah.liquidate(marketParams, BORROWER, 0, 1, hex"");

    assertEq(seizedAssets, 0, "seizedAssets");
    assertEq(repaidAssets, 1, "repaidAssets");
  }
}

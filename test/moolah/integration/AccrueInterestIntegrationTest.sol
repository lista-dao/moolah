// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract AccrueInterestIntegrationTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;

  function testAccrueInterestMarketNotCreated(MarketParams memory marketParamsFuzz) public {
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.accrueInterest(marketParamsFuzz);
  }

  function testAccrueInterestIrmZero(MarketParams memory marketParamsFuzz, uint256 blocks) public {
    marketParamsFuzz.irm = address(0);
    marketParamsFuzz.lltv = 0;
    blocks = _boundBlocks(blocks);

    vm.startPrank(OWNER);
    moolah.createMarket(marketParamsFuzz);
    vm.stopPrank();

    _forward(blocks);

    moolah.accrueInterest(marketParamsFuzz);
  }

  function testAccrueInterestNoTimeElapsed(uint256 amountSupplied, uint256 amountBorrowed) public {
    uint256 collateralPrice = moolah.getPrice(
      MarketParams({
        loanToken: address(loanToken),
        collateralToken: address(collateralToken),
        oracle: address(oracle),
        irm: address(irm),
        lltv: 0
      })
    );
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amountSupplied);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    uint256 totalBorrowBeforeAccrued = moolah.market(id).totalBorrowAssets;
    uint256 totalSupplyBeforeAccrued = moolah.market(id).totalSupplyAssets;
    uint256 totalSupplySharesBeforeAccrued = moolah.market(id).totalSupplyShares;

    moolah.accrueInterest(marketParams);

    assertEq(moolah.market(id).totalBorrowAssets, totalBorrowBeforeAccrued, "total borrow");
    assertEq(moolah.market(id).totalSupplyAssets, totalSupplyBeforeAccrued, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, totalSupplySharesBeforeAccrued, "total supply shares");
    assertEq(moolah.position(id, FEE_RECIPIENT).supplyShares, 0, "feeRecipient's supply shares");
  }

  function testAccrueInterestNoBorrow(uint256 amountSupplied, uint256 blocks) public {
    amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
    blocks = _boundBlocks(blocks);

    loanToken.setBalance(address(this), amountSupplied);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    _forward(blocks);

    uint256 totalBorrowBeforeAccrued = moolah.market(id).totalBorrowAssets;
    uint256 totalSupplyBeforeAccrued = moolah.market(id).totalSupplyAssets;
    uint256 totalSupplySharesBeforeAccrued = moolah.market(id).totalSupplyShares;

    moolah.accrueInterest(marketParams);

    assertEq(moolah.market(id).totalBorrowAssets, totalBorrowBeforeAccrued, "total borrow");
    assertEq(moolah.market(id).totalSupplyAssets, totalSupplyBeforeAccrued, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, totalSupplySharesBeforeAccrued, "total supply shares");
    assertEq(moolah.position(id, FEE_RECIPIENT).supplyShares, 0, "feeRecipient's supply shares");
    assertEq(moolah.market(id).lastUpdate, block.timestamp, "last update");
  }

  function testAccrueInterestNoFee(uint256 amountSupplied, uint256 amountBorrowed, uint256 blocks) public {
    uint256 collateralPrice = moolah.getPrice(
      MarketParams({
        loanToken: address(loanToken),
        collateralToken: address(collateralToken),
        oracle: address(oracle),
        irm: address(irm),
        lltv: 0
      })
    );
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
    blocks = _boundBlocks(blocks);

    loanToken.setBalance(address(this), amountSupplied);
    loanToken.setBalance(address(this), amountSupplied);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");

    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    _forward(blocks);

    uint256 borrowRate = (uint256(moolah.market(id).totalBorrowAssets).wDivDown(moolah.market(id).totalSupplyAssets)) /
      365 days;
    uint256 totalBorrowBeforeAccrued = moolah.market(id).totalBorrowAssets;
    uint256 totalSupplyBeforeAccrued = moolah.market(id).totalSupplyAssets;
    uint256 totalSupplySharesBeforeAccrued = moolah.market(id).totalSupplyShares;
    uint256 expectedAccruedInterest = totalBorrowBeforeAccrued.wMulDown(
      borrowRate.wTaylorCompounded(blocks * BLOCK_TIME)
    );

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.AccrueInterest(id, borrowRate, expectedAccruedInterest, 0);
    moolah.accrueInterest(marketParams);

    assertEq(moolah.market(id).totalBorrowAssets, totalBorrowBeforeAccrued + expectedAccruedInterest, "total borrow");
    assertEq(moolah.market(id).totalSupplyAssets, totalSupplyBeforeAccrued + expectedAccruedInterest, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, totalSupplySharesBeforeAccrued, "total supply shares");
    assertEq(moolah.position(id, FEE_RECIPIENT).supplyShares, 0, "feeRecipient's supply shares");
    assertEq(moolah.market(id).lastUpdate, block.timestamp, "last update");
  }

  struct AccrueInterestWithFeesTestParams {
    uint256 borrowRate;
    uint256 totalBorrowBeforeAccrued;
    uint256 totalSupplyBeforeAccrued;
    uint256 totalSupplySharesBeforeAccrued;
    uint256 expectedAccruedInterest;
    uint256 feeAmount;
    uint256 feeShares;
  }

  function testAccrueInterestWithFees(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 blocks,
    uint256 fee
  ) public {
    AccrueInterestWithFeesTestParams memory params;

    uint256 collateralPrice = moolah.getPrice(
      MarketParams({
        loanToken: address(loanToken),
        collateralToken: address(collateralToken),
        oracle: address(oracle),
        irm: address(irm),
        lltv: 0
      })
    );
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
    blocks = _boundBlocks(blocks);
    fee = bound(fee, 1, MAX_FEE);

    // Set fee parameters.
    vm.startPrank(OWNER);
    if (fee != moolah.market(id).fee) moolah.setFee(marketParams, fee);
    vm.stopPrank();

    loanToken.setBalance(address(this), amountSupplied);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    _forward(blocks);

    params.borrowRate =
      (uint256(moolah.market(id).totalBorrowAssets).wDivDown(moolah.market(id).totalSupplyAssets)) /
      365 days;
    params.totalBorrowBeforeAccrued = moolah.market(id).totalBorrowAssets;
    params.totalSupplyBeforeAccrued = moolah.market(id).totalSupplyAssets;
    params.totalSupplySharesBeforeAccrued = moolah.market(id).totalSupplyShares;
    params.expectedAccruedInterest = params.totalBorrowBeforeAccrued.wMulDown(
      params.borrowRate.wTaylorCompounded(blocks * BLOCK_TIME)
    );
    params.feeAmount = params.expectedAccruedInterest.wMulDown(fee);
    params.feeShares = params.feeAmount.toSharesDown(
      params.totalSupplyBeforeAccrued + params.expectedAccruedInterest - params.feeAmount,
      params.totalSupplySharesBeforeAccrued
    );

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.AccrueInterest(id, params.borrowRate, params.expectedAccruedInterest, params.feeShares);
    moolah.accrueInterest(marketParams);

    assertEq(
      moolah.market(id).totalSupplyAssets,
      params.totalSupplyBeforeAccrued + params.expectedAccruedInterest,
      "total supply"
    );
    assertEq(
      moolah.market(id).totalBorrowAssets,
      params.totalBorrowBeforeAccrued + params.expectedAccruedInterest,
      "total borrow"
    );
    assertEq(
      moolah.market(id).totalSupplyShares,
      params.totalSupplySharesBeforeAccrued + params.feeShares,
      "total supply shares"
    );
    assertEq(moolah.position(id, FEE_RECIPIENT).supplyShares, params.feeShares, "feeRecipient's supply shares");
    assertEq(moolah.market(id).lastUpdate, block.timestamp, "last update");
  }
}

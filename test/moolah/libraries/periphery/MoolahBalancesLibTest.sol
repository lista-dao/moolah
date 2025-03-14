// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../BaseTest.sol";

contract MoolahBalancesLibTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MoolahBalancesLib for IMoolah;

  function testVirtualAccrueInterest(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    (
      uint256 virtualTotalSupplyAssets,
      uint256 virtualTotalSupplyShares,
      uint256 virtualTotalBorrowAssets,
      uint256 virtualTotalBorrowShares
    ) = moolah.expectedMarketBalances(marketParams);

    moolah.accrueInterest(marketParams);

    assertEq(virtualTotalSupplyAssets, moolah.market(id).totalSupplyAssets, "total supply assets");
    assertEq(virtualTotalBorrowAssets, moolah.market(id).totalBorrowAssets, "total borrow assets");
    assertEq(virtualTotalSupplyShares, moolah.market(id).totalSupplyShares, "total supply shares");
    assertEq(virtualTotalBorrowShares, moolah.market(id).totalBorrowShares, "total borrow shares");
  }

  function testExpectedTotalSupply(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    uint256 expectedTotalSupplyAssets = moolah.expectedTotalSupplyAssets(marketParams);

    moolah.accrueInterest(marketParams);

    assertEq(expectedTotalSupplyAssets, moolah.market(id).totalSupplyAssets);
  }

  function testExpectedTotalBorrow(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    uint256 expectedTotalBorrowAssets = moolah.expectedTotalBorrowAssets(marketParams);

    moolah.accrueInterest(marketParams);

    assertEq(expectedTotalBorrowAssets, moolah.market(id).totalBorrowAssets);
  }

  function testExpectedTotalSupplyShares(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    uint256 expectedTotalSupplyShares = moolah.expectedTotalSupplyShares(marketParams);

    moolah.accrueInterest(marketParams);

    assertEq(expectedTotalSupplyShares, moolah.market(id).totalSupplyShares);
  }

  function testExpectedSupplyBalance(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    uint256 expectedSupplyBalance = moolah.expectedSupplyAssets(marketParams, address(this));

    moolah.accrueInterest(marketParams);

    uint256 actualSupplyBalance = moolah.position(id, address(this)).supplyShares.toAssetsDown(
      moolah.market(id).totalSupplyAssets,
      moolah.market(id).totalSupplyShares
    );

    assertEq(expectedSupplyBalance, actualSupplyBalance);
  }

  function testExpectedBorrowBalance(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 timeElapsed,
    uint256 fee
  ) public {
    _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

    uint256 expectedBorrowBalance = moolah.expectedBorrowAssets(marketParams, address(this));

    moolah.accrueInterest(marketParams);

    uint256 actualBorrowBalance = uint256(moolah.position(id, address(this)).borrowShares).toAssetsUp(
      moolah.market(id).totalBorrowAssets,
      moolah.market(id).totalBorrowShares
    );

    assertEq(expectedBorrowBalance, actualBorrowBalance);
  }

  function _generatePendingInterest(
    uint256 amountSupplied,
    uint256 amountBorrowed,
    uint256 blocks,
    uint256 fee
  ) internal {
    amountSupplied = bound(amountSupplied, 0, MAX_TEST_AMOUNT);
    amountBorrowed = bound(amountBorrowed, 0, amountSupplied);
    blocks = _boundBlocks(blocks);
    fee = bound(fee, 0, MAX_FEE);

    // Set fee parameters.
    vm.startPrank(OWNER);
    if (fee != moolah.market(id).fee) moolah.setFee(marketParams, fee);
    vm.stopPrank();

    if (amountSupplied > 0) {
      loanToken.setBalance(address(this), amountSupplied);
      moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");
      if (amountBorrowed > 0) {
        uint256 collateralPrice = moolah.getPrice(marketParams);
        collateralToken.setBalance(
          BORROWER,
          amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice)
        );

        vm.startPrank(BORROWER);
        moolah.supplyCollateral(
          marketParams,
          amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice),
          BORROWER,
          hex""
        );
        moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
      }
    }

    _forward(blocks);
  }
}

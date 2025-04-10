// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";

contract MoolahTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  function setUp() public override {
    super.setUp();

    vm.prank(OWNER);

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 100 * 1e8);

  }

  function test_liquidateRemain1() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);
    loanToken.setBalance(LIQUIDATOR, 100 ether);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 1 ether, BORROWER, "");

    moolah.borrow(marketParams, 80 ether, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(collateralToken), 100 * 1e8 - 1);

    uint256 borrowShares = moolah.position(marketParams.id(), BORROWER).borrowShares;
    Market memory market = moolah.market(marketParams.id());

    uint256 remainAssets = 1 ether;
    uint256 remainShares = remainAssets.toSharesDown(market.totalBorrowAssets, market.totalBorrowShares);

    vm.startPrank(LIQUIDATOR);
    moolah.liquidate(marketParams, BORROWER, 0, borrowShares - remainShares, "");
    vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
    moolah.liquidate(marketParams, BORROWER, 0, remainShares, "");
    uint256 collaterals = moolah.position(marketParams.id(), BORROWER).collateral;
    console.log("collaterals", collaterals);
    vm.stopPrank();

  }
}

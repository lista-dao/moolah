// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract SupplyCollateralIntegrationTest is BaseTest {
  function testSupplyCollateralMarketNotCreated(MarketParams memory marketParamsFuzz, uint256 amount) public {
    vm.assume(neq(marketParamsFuzz, marketParams));

    vm.prank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.supplyCollateral(marketParamsFuzz, amount, SUPPLIER, hex"");
  }

  function testSupplyCollateralZeroAmount(address SUPPLIER) public {
    vm.prank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ASSETS));
    moolah.supplyCollateral(marketParams, 0, SUPPLIER, hex"");
  }

  function testSupplyCollateralOnBehalfZeroAddress(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    vm.prank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.supplyCollateral(marketParams, amount, address(0), hex"");
  }

  function testSupplyCollateralTokenNotCreated(uint256 amount, address token) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    vm.assume(token.code.length == 0);

    marketParams.loanToken = token;
    marketParams.collateralToken = token;
    marketParams.oracle = address(oracle);

    vm.startPrank(OWNER);
    moolah.createMarket(marketParams);
    vm.stopPrank();

    vm.expectRevert(bytes(ErrorsLib.NO_CODE));
    moolah.supplyCollateral(marketParams, amount, ONBEHALF, hex"");
  }

  function testSupplyCollateral(uint256 amount) public {
    amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

    collateralToken.setBalance(SUPPLIER, amount);

    vm.prank(SUPPLIER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.SupplyCollateral(id, SUPPLIER, ONBEHALF, amount);
    moolah.supplyCollateral(marketParams, amount, ONBEHALF, hex"");

    assertEq(moolah.position(id, ONBEHALF).collateral, amount, "collateral");
    assertEq(collateralToken.balanceOf(SUPPLIER), 0, "SUPPLIER balance");
    assertEq(collateralToken.balanceOf(address(moolah)), amount, "moolah balance");
  }
}

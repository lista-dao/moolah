// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract WithdrawIntegrationTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;

  function testWithdrawMarketNotCreated(MarketParams memory marketParamsParamsFuzz) public {
    vm.assume(neq(marketParamsParamsFuzz, marketParams));

    vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
    moolah.withdraw(marketParamsParamsFuzz, 1, 0, address(this), address(this));
  }

  function testWithdrawZeroAmount(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.withdraw(marketParams, 0, 0, address(this), address(this));
  }

  function testWithdrawInconsistentInput(uint256 amount, uint256 shares) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);
    shares = bound(shares, 1, MAX_TEST_SHARES);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
    moolah.withdraw(marketParams, amount, shares, address(this), address(this));
  }

  function testWithdrawToZeroAddress(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.withdraw(marketParams, amount, 0, address(this), address(0));
  }

  function testWithdrawUnauthorized(address attacker, uint256 amount) public {
    vm.assume(attacker != address(this));
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    vm.prank(attacker);
    vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
    moolah.withdraw(marketParams, amount, 0, address(this), address(this));
  }

  function testWithdrawInsufficientLiquidity(uint256 amountSupplied, uint256 amountBorrowed) public {
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(
      0,
      amountBorrowed,
      moolah.getPrice(
        MarketParams({
          loanToken: address(loanToken),
          collateralToken: address(collateralToken),
          oracle: address(oracle),
          irm: address(irm),
          lltv: 0
        })
      )
    );
    amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT + 1);

    loanToken.setBalance(SUPPLIER, amountSupplied);

    vm.prank(SUPPLIER);
    moolah.supply(marketParams, amountSupplied, 0, SUPPLIER, hex"");

    collateralToken.setBalance(BORROWER, amountCollateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, RECEIVER);
    vm.stopPrank();

    vm.prank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_LIQUIDITY));
    moolah.withdraw(marketParams, amountSupplied, 0, SUPPLIER, RECEIVER);
  }

  function testWithdrawAssets(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn) public {
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(
      0,
      amountBorrowed,
      moolah.getPrice(
        MarketParams({
          loanToken: address(loanToken),
          collateralToken: address(collateralToken),
          oracle: address(oracle),
          irm: address(irm),
          lltv: 0
        })
      )
    );
    vm.assume(amountBorrowed < MAX_TEST_AMOUNT);
    amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
    amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

    loanToken.setBalance(address(this), amountSupplied);
    collateralToken.setBalance(BORROWER, amountCollateral);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
    uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, amountWithdrawn, expectedWithdrawnShares);
    (uint256 returnAssets, uint256 returnShares) = moolah.withdraw(
      marketParams,
      amountWithdrawn,
      0,
      address(this),
      RECEIVER
    );

    expectedSupplyShares -= expectedWithdrawnShares;

    assertEq(returnAssets, amountWithdrawn, "returned asset amount");
    assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
    assertEq(moolah.position(id, address(this)).supplyShares, expectedSupplyShares, "supply shares");
    assertEq(moolah.market(id).totalSupplyShares, expectedSupplyShares, "total supply shares");
    assertEq(moolah.market(id).totalSupplyAssets, amountSupplied - amountWithdrawn, "total supply");
    assertEq(loanToken.balanceOf(RECEIVER), amountWithdrawn, "RECEIVER balance");
    assertEq(loanToken.balanceOf(BORROWER), amountBorrowed, "borrower balance");
    assertEq(loanToken.balanceOf(address(moolah)), amountSupplied - amountBorrowed - amountWithdrawn, "moolah balance");
  }

  function testWithdrawShares(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn) public {
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(
      0,
      amountBorrowed,
      moolah.getPrice(
        MarketParams({
          loanToken: address(loanToken),
          collateralToken: address(collateralToken),
          oracle: address(oracle),
          irm: address(irm),
          lltv: 0
        })
      )
    );
    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

    uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
    uint256 availableLiquidity = amountSupplied - amountBorrowed;
    uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
    vm.assume(withdrawableShares != 0);

    sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
    uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

    loanToken.setBalance(address(this), amountSupplied);
    collateralToken.setBalance(BORROWER, amountCollateral);
    moolah.supply(marketParams, amountSupplied, 0, address(this), hex"");

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, amountCollateral, BORROWER, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
    vm.stopPrank();

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
    (uint256 returnAssets, uint256 returnShares) = moolah.withdraw(
      marketParams,
      0,
      sharesWithdrawn,
      address(this),
      RECEIVER
    );

    expectedSupplyShares -= sharesWithdrawn;

    assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
    assertEq(returnShares, sharesWithdrawn, "returned shares amount");
    assertEq(moolah.position(id, address(this)).supplyShares, expectedSupplyShares, "supply shares");
    assertEq(moolah.market(id).totalSupplyAssets, amountSupplied - expectedAmountWithdrawn, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, expectedSupplyShares, "total supply shares");
    assertEq(loanToken.balanceOf(RECEIVER), expectedAmountWithdrawn, "RECEIVER balance");
    assertEq(
      loanToken.balanceOf(address(moolah)),
      amountSupplied - amountBorrowed - expectedAmountWithdrawn,
      "moolah balance"
    );
  }

  function testWithdrawAssetsOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn) public {
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(
      0,
      amountBorrowed,
      moolah.getPrice(
        MarketParams({
          loanToken: address(loanToken),
          collateralToken: address(collateralToken),
          oracle: address(oracle),
          irm: address(irm),
          lltv: 0
        })
      )
    );
    vm.assume(amountBorrowed < MAX_TEST_AMOUNT);
    amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
    amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

    loanToken.setBalance(ONBEHALF, amountSupplied);
    collateralToken.setBalance(ONBEHALF, amountCollateral);

    vm.startPrank(ONBEHALF);
    moolah.supplyCollateral(marketParams, amountCollateral, ONBEHALF, hex"");
    moolah.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
    vm.stopPrank();

    uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
    uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

    uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

    vm.startPrank(BORROWER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, amountWithdrawn, expectedWithdrawnShares);
    (uint256 returnAssets, uint256 returnShares) = moolah.withdraw(
      marketParams,
      amountWithdrawn,
      0,
      ONBEHALF,
      RECEIVER
    );

    expectedSupplyShares -= expectedWithdrawnShares;

    assertEq(returnAssets, amountWithdrawn, "returned asset amount");
    assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
    assertEq(moolah.position(id, ONBEHALF).supplyShares, expectedSupplyShares, "supply shares");
    assertEq(moolah.market(id).totalSupplyAssets, amountSupplied - amountWithdrawn, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, expectedSupplyShares, "total supply shares");
    assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, amountWithdrawn, "RECEIVER balance");
    assertEq(loanToken.balanceOf(address(moolah)), amountSupplied - amountBorrowed - amountWithdrawn, "moolah balance");
  }

  function testWithdrawSharesOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn) public {
    uint256 amountCollateral;
    (amountCollateral, amountBorrowed, ) = _boundHealthyPosition(
      0,
      amountBorrowed,
      moolah.getPrice(
        MarketParams({
          loanToken: address(loanToken),
          collateralToken: address(collateralToken),
          oracle: address(oracle),
          irm: address(irm),
          lltv: 0
        })
      )
    );
    amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

    uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
    uint256 availableLiquidity = amountSupplied - amountBorrowed;
    uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
    vm.assume(withdrawableShares != 0);

    sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
    uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

    loanToken.setBalance(ONBEHALF, amountSupplied);
    collateralToken.setBalance(ONBEHALF, amountCollateral);

    vm.startPrank(ONBEHALF);
    moolah.supplyCollateral(marketParams, amountCollateral, ONBEHALF, hex"");
    moolah.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");
    moolah.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
    vm.stopPrank();

    uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

    vm.startPrank(BORROWER);

    vm.expectEmit(true, true, true, true, address(moolah));
    emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
    (uint256 returnAssets, uint256 returnShares) = moolah.withdraw(
      marketParams,
      0,
      sharesWithdrawn,
      ONBEHALF,
      RECEIVER
    );

    expectedSupplyShares -= sharesWithdrawn;

    assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
    assertEq(returnShares, sharesWithdrawn, "returned shares amount");
    assertEq(moolah.position(id, ONBEHALF).supplyShares, expectedSupplyShares, "supply shares");
    assertEq(moolah.market(id).totalSupplyAssets, amountSupplied - expectedAmountWithdrawn, "total supply");
    assertEq(moolah.market(id).totalSupplyShares, expectedSupplyShares, "total supply shares");
    assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, expectedAmountWithdrawn, "RECEIVER balance");
    assertEq(
      loanToken.balanceOf(address(moolah)),
      amountSupplied - amountBorrowed - expectedAmountWithdrawn,
      "moolah balance"
    );
  }
}

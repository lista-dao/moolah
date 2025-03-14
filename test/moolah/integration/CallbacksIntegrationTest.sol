// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract CallbacksIntegrationTest is
  BaseTest,
  IMoolahLiquidateCallback,
  IMoolahRepayCallback,
  IMoolahSupplyCallback,
  IMoolahSupplyCollateralCallback,
  IMoolahFlashLoanCallback
{
  using MathLib for uint256;
  using MarketParamsLib for MarketParams;

  // Callback functions.

  function onMoolahSupply(uint256 amount, bytes memory data) external {
    require(msg.sender == address(moolah));
    bytes4 selector;
    (selector, data) = abi.decode(data, (bytes4, bytes));
    if (selector == this.testSupplyCallback.selector) {
      loanToken.approve(address(moolah), amount);
    }
  }

  function onMoolahSupplyCollateral(uint256 amount, bytes memory data) external {
    require(msg.sender == address(moolah));
    bytes4 selector;
    (selector, data) = abi.decode(data, (bytes4, bytes));
    if (selector == this.testSupplyCollateralCallback.selector) {
      collateralToken.approve(address(moolah), amount);
    } else if (selector == this.testFlashActions.selector) {
      uint256 toBorrow = abi.decode(data, (uint256));
      collateralToken.setBalance(address(this), amount);
      moolah.borrow(marketParams, toBorrow, 0, address(this), address(this));
    }
  }

  function onMoolahRepay(uint256 amount, bytes memory data) external {
    require(msg.sender == address(moolah));
    bytes4 selector;
    (selector, data) = abi.decode(data, (bytes4, bytes));
    if (selector == this.testRepayCallback.selector) {
      loanToken.approve(address(moolah), amount);
    } else if (selector == this.testFlashActions.selector) {
      uint256 toWithdraw = abi.decode(data, (uint256));
      moolah.withdrawCollateral(marketParams, toWithdraw, address(this), address(this));
    }
  }

  function onMoolahLiquidate(uint256 repaid, bytes memory data) external {
    require(msg.sender == address(moolah));
    bytes4 selector;
    (selector, data) = abi.decode(data, (bytes4, bytes));
    if (selector == this.testLiquidateCallback.selector) {
      loanToken.approve(address(moolah), repaid);
    }
  }

  function onMoolahFlashLoan(uint256 amount, bytes memory data) external {
    require(msg.sender == address(moolah));
    bytes4 selector;
    (selector, data) = abi.decode(data, (bytes4, bytes));
    if (selector == this.testFlashLoan.selector) {
      assertEq(loanToken.balanceOf(address(this)), amount);
      loanToken.approve(address(moolah), amount);
    }
  }

  // Tests.

  function testFlashLoan(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    moolah.flashLoan(address(loanToken), amount, abi.encode(this.testFlashLoan.selector, hex""));

    assertEq(loanToken.balanceOf(address(moolah)), amount, "balanceOf");
  }

  function testFlashLoanZero() public {
    vm.expectRevert(bytes(ErrorsLib.ZERO_ASSETS));
    moolah.flashLoan(address(loanToken), 0, abi.encode(this.testFlashLoan.selector, hex""));
  }

  function testFlashLoanShouldRevertIfNotReimbursed(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    moolah.supply(marketParams, amount, 0, address(this), hex"");

    loanToken.approve(address(moolah), 0);

    vm.expectRevert(bytes(ErrorsLib.TRANSFER_FROM_REVERTED));
    moolah.flashLoan(
      address(loanToken),
      amount,
      abi.encode(this.testFlashLoanShouldRevertIfNotReimbursed.selector, hex"")
    );
  }

  function testSupplyCallback(uint256 amount) public {
    amount = bound(amount, 1, MAX_TEST_AMOUNT);

    loanToken.setBalance(address(this), amount);
    loanToken.approve(address(moolah), 0);

    vm.expectRevert();
    moolah.supply(marketParams, amount, 0, address(this), hex"");
    moolah.supply(marketParams, amount, 0, address(this), abi.encode(this.testSupplyCallback.selector, hex""));
  }

  function testSupplyCollateralCallback(uint256 amount) public {
    amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

    collateralToken.setBalance(address(this), amount);
    collateralToken.approve(address(moolah), 0);

    vm.expectRevert();
    moolah.supplyCollateral(marketParams, amount, address(this), hex"");
    moolah.supplyCollateral(
      marketParams,
      amount,
      address(this),
      abi.encode(this.testSupplyCollateralCallback.selector, hex"")
    );
  }

  function testRepayCallback(uint256 loanAmount) public {
    loanAmount = bound(loanAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
    uint256 collateralAmount;
    (collateralAmount, loanAmount, ) = _boundHealthyPosition(
      0,
      loanAmount,
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

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);

    moolah.supply(marketParams, loanAmount, 0, address(this), hex"");
    moolah.supplyCollateral(marketParams, collateralAmount, address(this), hex"");
    moolah.borrow(marketParams, loanAmount, 0, address(this), address(this));

    loanToken.approve(address(moolah), 0);

    vm.expectRevert();
    moolah.repay(marketParams, loanAmount, 0, address(this), hex"");
    moolah.repay(marketParams, loanAmount, 0, address(this), abi.encode(this.testRepayCallback.selector, hex""));
  }

  function testLiquidateCallback(uint256 loanAmount) public {
    loanAmount = bound(loanAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
    uint256 collateralAmount;
    (collateralAmount, loanAmount, ) = _boundHealthyPosition(
      0,
      loanAmount,
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

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);

    moolah.supply(marketParams, loanAmount, 0, address(this), hex"");
    moolah.supplyCollateral(marketParams, collateralAmount, address(this), hex"");
    moolah.borrow(marketParams, loanAmount, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), 0.99e18);

    loanToken.setBalance(address(this), loanAmount);
    loanToken.approve(address(moolah), 0);

    vm.expectRevert();
    moolah.liquidate(marketParams, address(this), collateralAmount, 0, hex"");
    moolah.liquidate(
      marketParams,
      address(this),
      collateralAmount,
      0,
      abi.encode(this.testLiquidateCallback.selector, hex"")
    );
  }

  function testFlashActions(uint256 loanAmount) public {
    loanAmount = bound(loanAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
    uint256 collateralAmount;
    (collateralAmount, loanAmount, ) = _boundHealthyPosition(
      0,
      loanAmount,
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

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), hex"");

    vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector));
    moolah.supplyCollateral(
      marketParams,
      collateralAmount,
      address(this),
      abi.encode(this.testFlashActions.selector, abi.encode(loanAmount))
    );
    assertEq(moolah.position(marketParams.id(), address(this)).borrowShares, 0, "no borrow");
  }
}

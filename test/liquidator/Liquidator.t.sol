// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../moolah/BaseTest.sol";

import { Liquidator, ILiquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";
import { MockOneInch } from "./mocks/MockOneInch.sol";

contract LiquidatorTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  ILiquidator liquidator;
  address BOT;
  MockOneInch oneInch;

  function setUp() public override {
    super.setUp();

    BOT = makeAddr("Bot");
    oneInch = new MockOneInch();

    Liquidator impl = new Liquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, OWNER, BOT)
    );
    liquidator = ILiquidator(address(proxy));
    vm.startPrank(OWNER);
    liquidator.setTokenWhitelist(address(collateralToken), true);
    liquidator.setTokenWhitelist(address(loanToken), true);

    liquidator.setMarketWhitelist(Id.unwrap(marketParams.id()), true);
    liquidator.setPairWhitelist(address(oneInch), true);
    vm.stopPrank();
  }

  function testLiquidate() public {
    uint256 loanAmount = 1e19;
    uint256 collateralAmount = 1e19;

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    loanToken.setBalance(address(liquidator), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), "");

    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");

    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);

    vm.startPrank(BOT);
    liquidator.liquidate(Id.unwrap(marketParams.id()), address(this), collateralAmount, 0);
    vm.stopPrank();

    assertEq(collateralToken.balanceOf(address(liquidator)), collateralAmount, "collateralToken balance");
  }

  function testFlashLiquidate() public {
    uint256 loanAmount = 1e19;
    uint256 collateralAmount = 1e19;

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), "");

    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");

    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);

    vm.startPrank(BOT);
    liquidator.flashLiquidate(
      Id.unwrap(marketParams.id()),
      address(this),
      collateralAmount,
      address(oneInch),
      abi.encodeWithSelector(
        oneInch.swap.selector,
        address(collateralToken),
        address(loanToken),
        collateralAmount,
        8e18
      )
    );
    vm.stopPrank();

    assertEq(collateralToken.balanceOf(address(liquidator)), 0, "collateralToken balance");
    assertGt(loanToken.balanceOf(address(liquidator)), 0, "loanToken balance");
  }

  function testSellToken() public {
    uint256 collateralAmount = 1e18;
    uint256 loanAmount = 1e18;
    collateralToken.setBalance(address(liquidator), collateralAmount);

    vm.startPrank(BOT);
    liquidator.sellToken(
      address(oneInch),
      address(collateralToken),
      address(loanToken),
      collateralAmount,
      loanAmount,
      abi.encodeWithSelector(
        oneInch.swap.selector,
        address(collateralToken),
        address(loanToken),
        collateralAmount,
        loanAmount
      )
    );
    vm.stopPrank();

    assertEq(loanToken.balanceOf(address(liquidator)), loanAmount, "loanToken balance");
    assertEq(collateralToken.balanceOf(address(liquidator)), 0, "collateralToken balance");
  }
}

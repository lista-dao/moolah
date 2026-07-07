// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { Liquidator, ILiquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";
import { MockOneInch } from "./mocks/MockOneInch.sol";
import { MockSmartProvider } from "./mocks/MockSmartProvider.sol";
import { MockStableSwapLPCollateral } from "./mocks/MockStableSwapLPCollateral.sol";

contract LiquidatorTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  ILiquidator liquidator;
  address BOT;
  MockOneInch oneInch;
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

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
    liquidator.setTokenWhitelist(BNB_ADDRESS, true);

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

  function testLiquidateRevertsForSmartCollateral() public {
    // Configure a smart-collateral market whose collateral's minter() -> smartProvider,
    // and smartProvider.TOKEN() -> the collateral (so _isSmartCollateral returns true).
    MockSmartProvider smartProvider = new MockSmartProvider(address(loanToken), address(collateralToken));
    MockStableSwapLPCollateral mockLPCollateral = new MockStableSwapLPCollateral(
      "MockLP",
      "MLP",
      address(smartProvider)
    );
    smartProvider.setCollateralToken(address(mockLPCollateral));

    MarketParams memory smartMarketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(mockLPCollateral),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    moolah.createMarket(smartMarketParams);
    bytes32 smartMarketId = Id.unwrap(smartMarketParams.id());

    vm.prank(OWNER);
    liquidator.setMarketWhitelist(smartMarketId, true);

    // Normal liquidate must reject smart collateral (use liquidateSmartCollateral instead),
    // otherwise the seized LP would be reflowed into the vault, which cannot redeem it.
    vm.prank(BOT);
    vm.expectRevert(Liquidator.SmartCollateralMustUseDedicatedFunction.selector);
    liquidator.liquidate(smartMarketId, address(1), 1e18, 0);
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
    assertEq(collateralToken.allowance(address(liquidator), address(oneInch)), 0, "collateralToken allowance");
  }

  function testSellBNB() public {
    uint256 collateralAmount = 1e18;
    uint256 loanAmount = 1e18;
    deal(address(liquidator), collateralAmount);

    vm.startPrank(BOT);
    liquidator.sellBNB(
      address(oneInch),
      address(loanToken),
      collateralAmount,
      loanAmount,
      abi.encodeWithSelector(oneInch.swap.selector, BNB_ADDRESS, address(loanToken), collateralAmount, loanAmount)
    );
    vm.stopPrank();

    assertEq(loanToken.balanceOf(address(liquidator)), loanAmount, "loanToken balance");
    assertEq(address(liquidator).balance, 0, "BNB balance");
  }

  function testBatchSetMarketWhitelist() public {
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = Id.unwrap(marketParams.id());
    vm.startPrank(OWNER);
    liquidator.batchSetMarketWhitelist(ids, false);
    vm.stopPrank();

    assertEq(liquidator.marketWhitelist(Id.unwrap(marketParams.id())), false, "market should be whitelisted");

    vm.startPrank(OWNER);
    liquidator.batchSetMarketWhitelist(ids, true);
    vm.stopPrank();

    assertEq(liquidator.marketWhitelist(Id.unwrap(marketParams.id())), true, "market should be whitelisted");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../moolah/BaseTest.sol";

import { PublicLiquidator, IPublicLiquidator } from "liquidator/PublicLiquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";
import { MockOneInch } from "./mocks/MockOneInch.sol";

contract PublicLiquidatorTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  IPublicLiquidator publicLiquidator;
  address BOT;
  MockOneInch oneInch;
  address USER;

  function setUp() public override {
    super.setUp();

    BOT = makeAddr("Bot");
    USER = makeAddr("User");
    oneInch = new MockOneInch();

    PublicLiquidator impl = new PublicLiquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, OWNER, BOT)
    );
    publicLiquidator = IPublicLiquidator(address(proxy));
  }

  /// @dev whitelist market couldn't be added to the whitelist again
  function testDuplicateWhitelist() public {
    vm.startPrank(BOT);
    vm.expectRevert("market is already open for liquidate");
    publicLiquidator.setMarketWhitelist(Id.unwrap(marketParams.id()), true);
    vm.stopPrank();
  }

  /// @dev using loan token to bid on collateral token
  function testLiquidate() public {
    uint256 loanAmount = 1e19;
    uint256 collateralAmount = 1e19;

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    loanToken.setBalance(address(publicLiquidator), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), "");

    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");

    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);

    vm.startPrank(USER);
    // give user some loan token to buy collateral token
    loanToken.setBalance(USER, 8e18 * 1.1);
    // approve publicLiquidator to spend USER's loan token
    loanToken.approve(address(publicLiquidator), 8e18 * 1.1);
    publicLiquidator.liquidate(Id.unwrap(marketParams.id()), address(this), collateralAmount, 0);
    vm.stopPrank();

    assertEq(collateralToken.balanceOf(USER), collateralAmount, "collateralToken balance");
  }

  /// @dev flashloan loan token and earn the difference after sold the collateral token
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

    vm.startPrank(USER);
    publicLiquidator.flashLiquidate(
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

    assertEq(collateralToken.balanceOf(address(USER)), 0, "collateralToken balance");
    assertGt(loanToken.balanceOf(address(USER)), 0, "loanToken balance");
  }

  /// @dev revert when trying to liquidate a market that is not whitelisted
  function testNonWhitelistLiquidate() public {
    uint256 loanAmount = 1e19;
    uint256 collateralAmount = 1e19;

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    loanToken.setBalance(address(publicLiquidator), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), "");

    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");

    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);

    // make this market only whitelisted address can liquidate
    vm.prank(OWNER);
    moolah.addLiquidationWhitelist(marketParams.id(), makeAddr("WHITELISTOR"));

    vm.startPrank(USER);
    // give user some loan token to buy collateral token
    loanToken.setBalance(USER, 8e18 * 1.1);
    // approve publicLiquidator to spend USER's loan token
    loanToken.approve(address(publicLiquidator), 8e18 * 1.1);
    vm.expectRevert(bytes4(keccak256("NotWhitelisted()")));
    publicLiquidator.liquidate(Id.unwrap(marketParams.id()), address(this), collateralAmount, 0);
    vm.stopPrank();
  }
}

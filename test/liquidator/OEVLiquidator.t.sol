// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OEVLiquidator } from "liquidator/OEVLiquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";

contract OEVLiquidatorTest is BaseTest {
  using MarketParamsLib for MarketParams;

  OEVLiquidator liquidator;
  address ATLAS;
  address PAUSER;
  bytes32 marketId;

  function setUp() public override {
    super.setUp();

    ATLAS = makeAddr("Atlas");
    PAUSER = makeAddr("Pauser");
    marketId = Id.unwrap(marketParams.id());

    OEVLiquidator impl = new OEVLiquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, OWNER, PAUSER, ATLAS)
    );
    liquidator = OEVLiquidator(address(proxy));
    vm.prank(OWNER);
    liquidator.setMarketWhitelist(marketId, true);

    // unhealthy position: 10 collateral, 8 debt, collateral price drops 90%
    loanToken.setBalance(address(this), 1e19);
    collateralToken.setBalance(address(this), 1e19);
    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);
    moolah.supply(marketParams, 1e19, 0, address(this), "");
    moolah.supplyCollateral(marketParams, 1e19, address(this), "");
    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));
    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);

    loanToken.setBalance(ATLAS, 1e19);
    vm.prank(ATLAS);
    loanToken.approve(address(liquidator), type(uint256).max);
  }

  function testLiquidate() public {
    vm.prank(ATLAS);
    (uint256 seized, uint256 repaid) = liquidator.liquidate(marketId, address(this), 1e18, 0);

    assertEq(seized, 1e18, "seized");
    assertGt(repaid, 0, "repaid");
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
    assertEq(loanToken.balanceOf(ATLAS), 1e19 - repaid, "atlas loan");
    assertEq(collateralToken.balanceOf(address(liquidator)), 0, "liquidator collateral");
    assertEq(loanToken.balanceOf(address(liquidator)), 0, "liquidator loan");
    assertEq(loanToken.allowance(address(liquidator), address(moolah)), 0, "moolah allowance");
  }

  function testLiquidateOnlyOEV() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, liquidator.OEV())
    );
    vm.prank(OWNER);
    liquidator.liquidate(marketId, address(this), 1e18, 0);
  }

  function testLiquidateMarketNotWhitelisted() public {
    vm.prank(OWNER);
    liquidator.setMarketWhitelist(marketId, false);

    vm.expectRevert(OEVLiquidator.NotWhitelisted.selector);
    vm.prank(ATLAS);
    liquidator.liquidate(marketId, address(this), 1e18, 0);
  }

  function testPauseUnpause() public {
    vm.prank(PAUSER);
    liquidator.pause();

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vm.prank(ATLAS);
    liquidator.liquidate(marketId, address(this), 1e18, 0);

    // PAUSER cannot unpause; MANAGER can
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, liquidator.MANAGER())
    );
    vm.prank(PAUSER);
    liquidator.unpause();

    vm.prank(OWNER);
    liquidator.unpause();
    vm.prank(ATLAS);
    liquidator.liquidate(marketId, address(this), 1e18, 0);
  }

  function testOnMoolahLiquidateOnlyMoolah() public {
    vm.expectRevert(OEVLiquidator.OnlyMoolah.selector);
    vm.prank(ATLAS);
    liquidator.onMoolahLiquidate(1, abi.encode(address(loanToken), ATLAS));
  }
}

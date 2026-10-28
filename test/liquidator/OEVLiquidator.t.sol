// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OEVLiquidator } from "liquidator/OEVLiquidator.sol";
import { IMoolah as ILiquidatorMoolah } from "liquidator/Interface.sol";

/// @dev OEV payer: records what it holds and receives when its callback runs, then pays the repayment.
contract OEVPayerMock {
  ERC20Mock immutable COLLATERAL_TOKEN;
  ERC20Mock immutable LOAN_TOKEN;
  uint256 public collateralAtCallback;
  uint256 public repaidAtCallback;
  bytes public payloadAtCallback;

  constructor(ERC20Mock collateralToken, ERC20Mock loanToken) {
    COLLATERAL_TOKEN = collateralToken;
    LOAN_TOKEN = loanToken;
  }

  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    collateralAtCallback = COLLATERAL_TOKEN.balanceOf(address(this));
    repaidAtCallback = repaidAssets;
    payloadAtCallback = data;
    require(LOAN_TOKEN.transfer(msg.sender, repaidAssets));
  }
}

contract OEVLiquidatorTest is BaseTest {
  OEVLiquidator liquidator;
  OEVPayerMock payer;
  address ATLAS;
  address PAUSER;
  ILiquidatorMoolah.MarketParams params;

  function setUp() public override {
    super.setUp();

    payer = new OEVPayerMock(collateralToken, loanToken);
    ATLAS = address(payer);
    PAUSER = makeAddr("Pauser");
    params = ILiquidatorMoolah.MarketParams(
      marketParams.loanToken,
      marketParams.collateralToken,
      marketParams.oracle,
      marketParams.irm,
      marketParams.lltv
    );

    OEVLiquidator impl = new OEVLiquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, OWNER, PAUSER, ATLAS)
    );
    liquidator = OEVLiquidator(address(proxy));

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
  }

  function testLiquidate() public {
    // stray collateral already on the liquidator must not be forwarded to the payer
    collateralToken.setBalance(address(liquidator), 5e17);

    vm.prank(ATLAS);
    (uint256 seized, uint256 repaid) = liquidator.liquidate(params, address(this), 1e18, 0, "atlas");

    assertEq(seized, 1e18, "seized");
    assertGt(repaid, 0, "repaid");
    // collateral is delivered before the payer callback runs
    assertEq(payer.collateralAtCallback(), seized, "collateral at callback");
    assertEq(payer.repaidAtCallback(), repaid, "repaid at callback");
    assertEq(payer.payloadAtCallback(), "atlas", "payload at callback");
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
    assertEq(loanToken.balanceOf(ATLAS), 1e19 - repaid, "atlas loan");
    assertEq(collateralToken.balanceOf(address(liquidator)), 5e17, "liquidator collateral");
    assertEq(loanToken.balanceOf(address(liquidator)), 0, "liquidator loan");
    assertEq(loanToken.allowance(address(liquidator), address(moolah)), 0, "moolah allowance");
  }

  function testLiquidateOnlyOEV() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, liquidator.OEV())
    );
    vm.prank(OWNER);
    liquidator.liquidate(params, address(this), 1e18, 0, "");
  }

  function testPauseUnpause() public {
    vm.prank(PAUSER);
    liquidator.pause();

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vm.prank(ATLAS);
    liquidator.liquidate(params, address(this), 1e18, 0, "");

    // PAUSER cannot unpause; MANAGER can
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, liquidator.MANAGER())
    );
    vm.prank(PAUSER);
    liquidator.unpause();

    vm.prank(OWNER);
    liquidator.unpause();
    vm.prank(ATLAS);
    liquidator.liquidate(params, address(this), 1e18, 0, "");
  }

  function testOnMoolahLiquidateOnlyMoolah() public {
    vm.expectRevert(OEVLiquidator.OnlyMoolah.selector);
    vm.prank(ATLAS);
    liquidator.onMoolahLiquidate(1, abi.encode(address(loanToken), address(collateralToken), 0, ATLAS, ""));
  }
}

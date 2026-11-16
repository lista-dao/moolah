// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { BrokerLiquidator } from "liquidator/BrokerLiquidator.sol";
import { V3Liquidator } from "liquidator/V3Liquidator.sol";
import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";

interface IPausableLiquidator {
  function pause() external;
  function unpause() external;
  function paused() external view returns (bool);
  function withdrawERC20(address token, uint256 amount) external;
  function withdrawETH(uint256 amount) external;
}

/// @dev Kill-switch coverage for Liquidator / BrokerLiquidator / V3Liquidator / PublicLiquidator:
///      PAUSER pauses, MANAGER unpauses, every liquidation (and, for the BOT liquidators, every
///      sell/redeem) entry point reverts while paused, and withdraw* stays open.
contract LiquidatorPauseTest is BaseTest {
  using MarketParamsLib for MarketParams;

  bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER");
  address internal constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  address internal BOT_ADDR;
  address internal MANAGER_ADDR;
  address internal PAUSER_ADDR;
  address internal USER;

  Liquidator internal liquidator;
  BrokerLiquidator internal brokerLiquidator;
  V3Liquidator internal v3Liquidator;
  PublicLiquidator internal publicLiquidator;

  function setUp() public override {
    super.setUp();

    BOT_ADDR = makeAddr("Bot");
    MANAGER_ADDR = makeAddr("Manager");
    PAUSER_ADDR = makeAddr("Pauser");
    USER = makeAddr("User");

    Liquidator lImpl = new Liquidator(address(moolah));
    liquidator = Liquidator(
      payable(
        address(
          new ERC1967Proxy(address(lImpl), abi.encodeCall(Liquidator.initialize, (OWNER, MANAGER_ADDR, BOT_ADDR)))
        )
      )
    );

    BrokerLiquidator bImpl = new BrokerLiquidator(address(moolah));
    brokerLiquidator = BrokerLiquidator(
      payable(
        address(
          new ERC1967Proxy(address(bImpl), abi.encodeCall(BrokerLiquidator.initialize, (OWNER, MANAGER_ADDR, BOT_ADDR)))
        )
      )
    );

    V3Liquidator vImpl = new V3Liquidator(address(moolah));
    v3Liquidator = V3Liquidator(
      payable(
        address(
          new ERC1967Proxy(
            address(vImpl),
            abi.encodeCall(V3Liquidator.initialize, (OWNER, MANAGER_ADDR, BOT_ADDR, address(0)))
          )
        )
      )
    );

    PublicLiquidator pImpl = new PublicLiquidator(address(moolah));
    publicLiquidator = PublicLiquidator(
      payable(
        address(
          new ERC1967Proxy(address(pImpl), abi.encodeCall(PublicLiquidator.initialize, (OWNER, MANAGER_ADDR, BOT_ADDR)))
        )
      )
    );

    // PAUSER is not granted by initialize; the admin grants it post-deploy / post-upgrade.
    vm.startPrank(OWNER);
    liquidator.grantRole(PAUSER_ROLE, PAUSER_ADDR);
    brokerLiquidator.grantRole(PAUSER_ROLE, PAUSER_ADDR);
    v3Liquidator.grantRole(PAUSER_ROLE, PAUSER_ADDR);
    publicLiquidator.grantRole(PAUSER_ROLE, PAUSER_ADDR);
    vm.stopPrank();
  }

  /* ───────────────────────────── roles ───────────────────────────── */

  function test_pauseRoles_allLiquidators() public {
    address[4] memory targets = [
      address(liquidator),
      address(brokerLiquidator),
      address(v3Liquidator),
      address(publicLiquidator)
    ];
    for (uint256 i = 0; i < targets.length; i++) {
      IPausableLiquidator t = IPausableLiquidator(targets[i]);
      assertFalse(t.paused(), "starts unpaused");

      // only PAUSER can pause (not BOT, not MANAGER)
      vm.prank(BOT_ADDR);
      vm.expectRevert(
        abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOT_ADDR, PAUSER_ROLE)
      );
      t.pause();
      vm.prank(MANAGER_ADDR);
      vm.expectRevert(
        abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, MANAGER_ADDR, PAUSER_ROLE)
      );
      t.pause();

      vm.prank(PAUSER_ADDR);
      t.pause();
      assertTrue(t.paused(), "paused");

      // only MANAGER can unpause (PAUSER cannot)
      vm.prank(PAUSER_ADDR);
      vm.expectRevert(
        abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER_ADDR, MANAGER)
      );
      t.unpause();

      vm.prank(MANAGER_ADDR);
      t.unpause();
      assertFalse(t.paused(), "unpaused");
    }
  }

  /* ──────────────────────── Liquidator ──────────────────────────── */

  function test_liquidator_pausedBlocksAllBotOps() public {
    vm.prank(PAUSER_ADDR);
    liquidator.pause();

    bytes32 mid = Id.unwrap(marketParams.id());
    address a = makeAddr("any");

    vm.startPrank(BOT_ADDR);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.liquidate(mid, a, 1, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.flashLiquidate(mid, a, 1, a, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.flashLiquidate(mid, a, 1, a, a, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.liquidateSmartCollateral(mid, a, a, 1, 0, abi.encode(0, 0));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.flashLiquidateSmartCollateral(mid, a, a, 1, a, a, "", "", abi.encode(0, 0));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.redeemSmartCollateral(a, 1, 0, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.sellToken(a, a, a, 1, 0, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.sellToken(a, a, a, a, 1, 0, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.sellBNB(a, a, 1, 0, "");
    vm.stopPrank();
  }

  function test_liquidator_unpauseRestoresLiquidation() public {
    bytes32 mid = Id.unwrap(marketParams.id());
    vm.prank(MANAGER_ADDR);
    liquidator.setMarketWhitelist(mid, true);

    uint256 collateralAmount = _openUnhealthyPosition();
    loanToken.setBalance(address(liquidator), 1e19);

    vm.prank(PAUSER_ADDR);
    liquidator.pause();

    vm.prank(BOT_ADDR);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    liquidator.liquidate(mid, address(this), collateralAmount, 0);

    vm.prank(MANAGER_ADDR);
    liquidator.unpause();

    vm.prank(BOT_ADDR);
    liquidator.liquidate(mid, address(this), collateralAmount, 0);
    assertEq(collateralToken.balanceOf(address(liquidator)), collateralAmount, "seized after unpause");
  }

  function test_liquidator_withdrawOpenWhenPaused() public {
    _assertWithdrawOpenWhenPaused(address(liquidator));
  }

  /* ───────────────────── BrokerLiquidator ───────────────────────── */

  function test_brokerLiquidator_pausedBlocksAllBotOps() public {
    vm.prank(PAUSER_ADDR);
    brokerLiquidator.pause();

    bytes32 mid = Id.unwrap(marketParams.id());
    address a = makeAddr("any");

    vm.startPrank(BOT_ADDR);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.liquidate(mid, a, 1, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.flashLiquidate(mid, a, 1, a, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.liquidateSmartCollateral(mid, a, a, 1, 0, abi.encode(0, 0));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.flashLiquidateSmartCollateral(mid, a, a, 1, a, a, "", "", abi.encode(0, 0));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.redeemSmartCollateral(a, 1, 0, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.sellToken(a, a, a, 1, 0, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    brokerLiquidator.sellBNB(a, a, 1, 0, "");
    vm.stopPrank();

    // after unpause the pause gate is lifted: the call proceeds to its own whitelist check
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.unpause();
    vm.prank(BOT_ADDR);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    brokerLiquidator.liquidate(mid, a, 1, 0);
  }

  function test_brokerLiquidator_withdrawOpenWhenPaused() public {
    _assertWithdrawOpenWhenPaused(address(brokerLiquidator));
  }

  /* ─────────────────────── V3Liquidator ─────────────────────────── */

  function test_v3Liquidator_pausedBlocksAllBotOps() public {
    vm.prank(PAUSER_ADDR);
    v3Liquidator.pause();

    bytes32 mid = Id.unwrap(marketParams.id());
    address a = makeAddr("any");
    V3Liquidator.FlashLiquidateParams memory p;

    vm.startPrank(BOT_ADDR);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.liquidate(mid, a, 1, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.flashLiquidate(mid, a, 1, p);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.redeemV3Shares(a, 1, 0, 0, address(v3Liquidator));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.sellToken(a, a, a, 1, 0, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.sellToken(a, a, a, a, 1, 0, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    v3Liquidator.sellBNB(a, a, 1, 0, "");
    vm.stopPrank();

    vm.prank(MANAGER_ADDR);
    v3Liquidator.unpause();
    vm.prank(BOT_ADDR);
    vm.expectRevert(V3Liquidator.NotWhitelisted.selector);
    v3Liquidator.liquidate(mid, a, 1, 0);
  }

  function test_v3Liquidator_withdrawOpenWhenPaused() public {
    _assertWithdrawOpenWhenPaused(address(v3Liquidator));
  }

  /* ───────────────────── PublicLiquidator ───────────────────────── */

  function test_publicLiquidator_pausedBlocksLiquidations() public {
    vm.prank(PAUSER_ADDR);
    publicLiquidator.pause();

    bytes32 mid = Id.unwrap(marketParams.id());
    address a = makeAddr("any");

    // public entry points: any caller is blocked
    vm.startPrank(USER);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.liquidate(mid, a, 1, 0);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.liquidateWithCollTransferOpt(mid, a, 1, 0, true);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.flashLiquidate(mid, a, 1, a, "");
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.liquidateSmartCollateral(mid, a, a, 1, 0, abi.encode(0, 0));
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.flashLiquidateSmartCollateral(mid, a, a, 1, a, a, "", "", abi.encode(0, 0));

    // redeemSmartCollateral stays open while paused: it reaches its own whitelist check instead
    vm.expectRevert(PublicLiquidator.NotWhitelisted.selector);
    publicLiquidator.redeemSmartCollateral(a, 1, 0, 0);
    vm.stopPrank();
  }

  function test_publicLiquidator_unpauseRestoresLiquidation() public {
    bytes32 mid = Id.unwrap(marketParams.id());
    uint256 collateralAmount = _openUnhealthyPosition();

    loanToken.setBalance(USER, 8e18 * 1.1);
    vm.prank(USER);
    loanToken.approve(address(publicLiquidator), 8e18 * 1.1);

    vm.prank(PAUSER_ADDR);
    publicLiquidator.pause();

    vm.prank(USER);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    publicLiquidator.liquidate(mid, address(this), collateralAmount, 0);

    vm.prank(MANAGER_ADDR);
    publicLiquidator.unpause();

    vm.prank(USER);
    publicLiquidator.liquidate(mid, address(this), collateralAmount, 0);
    assertEq(collateralToken.balanceOf(USER), collateralAmount, "seized after unpause");
  }

  /* ─────────────────────────── helpers ──────────────────────────── */

  /// @dev Supplies, borrows 8e18 against 1e19 collateral, then drops the collateral price 10x.
  function _openUnhealthyPosition() internal returns (uint256 collateralAmount) {
    uint256 loanAmount = 1e19;
    collateralAmount = 1e19;

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    loanToken.setBalance(address(this), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    moolah.supply(marketParams, loanAmount, 0, address(this), "");
    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");
    moolah.borrow(marketParams, 8e18, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 10);
  }

  /// @dev withdrawERC20 / withdrawETH must keep working during an incident so funds can be pulled out.
  function _assertWithdrawOpenWhenPaused(address target) internal {
    loanToken.setBalance(target, 1e18);
    vm.deal(target, 1 ether);

    vm.prank(PAUSER_ADDR);
    IPausableLiquidator(target).pause();

    vm.startPrank(MANAGER_ADDR);
    IPausableLiquidator(target).withdrawERC20(address(loanToken), 1e18);
    IPausableLiquidator(target).withdrawETH(1 ether);
    vm.stopPrank();

    assertEq(loanToken.balanceOf(MANAGER_ADDR), 1e18, "erc20 withdrawn");
    assertEq(MANAGER_ADDR.balance, 1 ether, "eth withdrawn");
  }
}

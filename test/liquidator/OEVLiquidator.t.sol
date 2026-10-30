// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OEVLiquidator } from "liquidator/OEVLiquidator.sol";
import { IMoolah as ILiquidatorMoolah } from "liquidator/Interface.sol";

/// @dev Calls `reentryTarget` with `reentryData` once and records the revert data; the call must fail.
abstract contract Reenterer {
  address reentryTarget;
  bytes reentryData;
  bytes public reentryError;

  function setReentry(address target, bytes calldata data) external {
    reentryTarget = target;
    reentryData = data;
  }

  function _reenter() internal {
    if (reentryData.length == 0) return;
    bytes memory data = reentryData;
    delete reentryData;
    (bool ok, bytes memory err) = reentryTarget.call(data);
    require(!ok, "reentry succeeded");
    reentryError = err;
  }
}

/// @dev OEV payer: records what it holds and receives when its callback runs, then pays the repayment.
contract OEVPayerMock is Reenterer {
  ERC20Mock immutable COLLATERAL_TOKEN;
  ERC20Mock immutable LOAN_TOKEN;
  uint256 public collateralAtCallback;
  uint256 public repaidAtCallback;
  bytes public payloadAtCallback;

  constructor(ERC20Mock collateralToken, ERC20Mock loanToken) {
    COLLATERAL_TOKEN = collateralToken;
    LOAN_TOKEN = loanToken;
  }

  function onOEVLiquidate(uint256 repaidAssets, bytes calldata data) external {
    _reenter();
    collateralAtCallback = COLLATERAL_TOKEN.balanceOf(address(this));
    repaidAtCallback = repaidAssets;
    payloadAtCallback = data;
    require(LOAN_TOKEN.transfer(msg.sender, repaidAssets));
  }
}

/// @dev Malicious token: re-enters on transfer.
contract ReentrantERC20Mock is ERC20Mock, Reenterer {
  function transfer(address to, uint256 amount) public override returns (bool) {
    _reenter();
    return super.transfer(to, amount);
  }
}

contract OEVLiquidatorTest is BaseTest {
  OEVLiquidator liquidator;
  OEVPayerMock payer;
  address ATLAS;
  address _MANAGER;
  address PAUSER;
  ILiquidatorMoolah.MarketParams params;

  function setUp() public override {
    super.setUp();

    payer = new OEVPayerMock(collateralToken, loanToken);
    ATLAS = address(payer);
    _MANAGER = makeAddr("Manager");
    PAUSER = makeAddr("Pauser");
    params = _toLiquidatorParams(marketParams);

    OEVLiquidator impl = new OEVLiquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, _MANAGER, PAUSER, ATLAS)
    );
    liquidator = OEVLiquidator(address(proxy));

    _openUnhealthyPosition(marketParams);

    loanToken.setBalance(ATLAS, 1e19);
  }

  function testLiquidate() public {
    // stray collateral already on the liquidator must not be forwarded to the payer
    collateralToken.setBalance(address(liquidator), 5e17);

    vm.recordLogs();
    vm.prank(ATLAS);
    (uint256 seized, uint256 repaid) = liquidator.liquidate(params, address(this), 1e18, 0, "atlas");
    _assertLiquidatedEvent(seized, repaid, 0);

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

  /// @dev seizedAssets = 0: Moolah derives the seized amount from repaidShares.
  function testLiquidateByRepaidShares() public {
    uint256 borrowShares = moolah.position(id, address(this)).borrowShares;
    uint256 repaidShares = borrowShares / 100;

    vm.recordLogs();
    vm.prank(ATLAS);
    (uint256 seized, uint256 repaid) = liquidator.liquidate(params, address(this), 0, repaidShares, "");
    _assertLiquidatedEvent(seized, repaid, repaidShares);

    assertGt(seized, 0, "seized");
    assertEq(moolah.position(id, address(this)).borrowShares, borrowShares - repaidShares, "borrow shares");
    assertEq(payer.repaidAtCallback(), repaid, "repaid at callback");
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
    assertEq(loanToken.balanceOf(ATLAS), 1e19 - repaid, "atlas loan");
    assertEq(loanToken.allowance(address(liquidator), address(moolah)), 0, "moolah allowance");
  }

  function testLiquidateOnlyOEV() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, liquidator.OEV())
    );
    vm.prank(OWNER);
    liquidator.liquidate(params, address(this), 1e18, 0, "");
  }

  /// @dev the OEV setup: the market's liquidation whitelist names only this contract.
  function testLiquidateOEVExclusiveMarket() public {
    _addLiquidationWhitelist(address(liquidator));

    // any other liquidator is locked out
    vm.expectRevert(bytes(ErrorsLib.NOT_LIQUIDATION_WHITELIST));
    vm.prank(LIQUIDATOR);
    moolah.liquidate(marketParams, address(this), 1e18, 0, "");

    vm.prank(ATLAS);
    (uint256 seized, ) = liquidator.liquidate(params, address(this), 1e18, 0, "");
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
  }

  function testLiquidateNotWhitelisted() public {
    _addLiquidationWhitelist(LIQUIDATOR);

    vm.expectRevert(bytes(ErrorsLib.NOT_LIQUIDATION_WHITELIST));
    vm.prank(ATLAS);
    liquidator.liquidate(params, address(this), 1e18, 0, "");
  }

  function testRotateOEV() public {
    OEVPayerMock newPayer = new OEVPayerMock(collateralToken, loanToken);
    loanToken.setBalance(address(newPayer), 1e19);
    bytes32 oevRole = liquidator.OEV();

    // OEV's role admin is MANAGER, not the TimeLock admin
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, liquidator.MANAGER())
    );
    vm.prank(OWNER);
    liquidator.grantRole(oevRole, address(newPayer));

    vm.startPrank(_MANAGER);
    liquidator.grantRole(oevRole, address(newPayer));
    liquidator.revokeRole(oevRole, ATLAS);
    vm.stopPrank();

    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATLAS, oevRole));
    vm.prank(ATLAS);
    liquidator.liquidate(params, address(this), 1e18, 0, "");

    vm.prank(address(newPayer));
    (uint256 seized, ) = liquidator.liquidate(params, address(this), 1e18, 0, "");
    assertEq(collateralToken.balanceOf(address(newPayer)), seized, "new payer collateral");
  }

  function testWithdrawERC20() public {
    loanToken.setBalance(address(liquidator), 1e18);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, liquidator.MANAGER())
    );
    vm.prank(OWNER);
    liquidator.withdrawERC20(address(loanToken), 1e18);

    vm.prank(_MANAGER);
    liquidator.withdrawERC20(address(loanToken), 1e18);
    assertEq(loanToken.balanceOf(_MANAGER), 1e18, "manager loan");
    assertEq(loanToken.balanceOf(address(liquidator)), 0, "liquidator loan");
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

    vm.prank(_MANAGER);
    liquidator.unpause();
    vm.prank(ATLAS);
    liquidator.liquidate(params, address(this), 1e18, 0, "");
  }

  function testUpgrade() public {
    address newImpl = address(new OEVLiquidator(address(moolah)));

    // only DEFAULT_ADMIN_ROLE (TimeLock) can upgrade
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _MANAGER, DEFAULT_ADMIN_ROLE)
    );
    vm.prank(_MANAGER);
    liquidator.upgradeToAndCall(newImpl, "");

    vm.prank(OWNER);
    liquidator.upgradeToAndCall(newImpl, "");

    bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    assertEq(address(uint160(uint256(vm.load(address(liquidator), implSlot)))), newImpl, "implementation");
    // MOOLAH is an immutable of the new implementation; roles live in proxy storage
    assertEq(liquidator.MOOLAH(), address(moolah), "moolah");
    assertTrue(liquidator.hasRole(DEFAULT_ADMIN_ROLE, OWNER), "admin");
    assertTrue(liquidator.hasRole(liquidator.MANAGER(), _MANAGER), "manager");
    assertTrue(liquidator.hasRole(liquidator.PAUSER(), PAUSER), "pauser");
    assertTrue(liquidator.hasRole(liquidator.OEV(), ATLAS), "oev");
    assertEq(liquidator.getRoleAdmin(liquidator.OEV()), liquidator.MANAGER(), "oev role admin");

    vm.prank(ATLAS);
    (uint256 seized, ) = liquidator.liquidate(params, address(this), 1e18, 0, "");
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
  }

  /// @dev the payer holds OEV, so only the reentrancy guard stops it (Moolah's own guard reverts the same way).
  function testLiquidateReentrancyViaCallback() public {
    payer.setReentry(
      address(liquidator),
      abi.encodeCall(OEVLiquidator.liquidate, (params, address(this), 1e18, 0, ""))
    );

    vm.prank(ATLAS);
    (uint256 seized, ) = liquidator.liquidate(params, address(this), 1e18, 0, "");

    assertEq(
      payer.reentryError(),
      abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector),
      "reentry error"
    );
    assertEq(collateralToken.balanceOf(ATLAS), seized, "atlas collateral");
  }

  function testLiquidateReentrancyViaToken() public {
    ReentrantERC20Mock token = new ReentrantERC20Mock();
    MarketParams memory mp = MarketParams(
      address(loanToken),
      address(token),
      address(oracle),
      address(irm),
      DEFAULT_TEST_LLTV
    );
    vm.prank(OWNER);
    moolah.createMarket(mp);
    _openUnhealthyPosition(mp);
    ILiquidatorMoolah.MarketParams memory lp = _toLiquidatorParams(mp);

    // fires on Moolah's collateral transfer to the liquidator, inside liquidate
    token.setReentry(address(liquidator), abi.encodeCall(OEVLiquidator.liquidate, (lp, address(this), 1e18, 0, "")));

    vm.prank(ATLAS);
    (uint256 seized, ) = liquidator.liquidate(lp, address(this), 1e18, 0, "");

    assertEq(
      token.reentryError(),
      abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector),
      "reentry error"
    );
    assertEq(token.balanceOf(ATLAS), seized, "atlas collateral");
  }

  function testOnMoolahLiquidateOnlyMoolah() public {
    vm.expectRevert(OEVLiquidator.OnlyMoolah.selector);
    vm.prank(ATLAS);
    liquidator.onMoolahLiquidate(1, abi.encode(address(loanToken), address(collateralToken), 0, ATLAS, ""));
  }

  /// @dev unhealthy position for this contract: 10 collateral, 8 debt, then collateral price drops 90%.
  function _openUnhealthyPosition(MarketParams memory mp) internal {
    ERC20Mock collateral = ERC20Mock(mp.collateralToken);
    collateral.approve(address(moolah), type(uint256).max);
    loanToken.setBalance(address(this), 1e19);
    collateral.setBalance(address(this), 1e19);
    oracle.setPrice(address(collateral), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);
    moolah.supply(mp, 1e19, 0, address(this), "");
    moolah.supplyCollateral(mp, 1e19, address(this), "");
    moolah.borrow(mp, 8e18, 0, address(this), address(this));
    oracle.setPrice(address(collateral), ORACLE_PRICE_SCALE / 10);
  }

  function _addLiquidationWhitelist(address account) internal {
    Id[] memory ids = new Id[](1);
    ids[0] = id;
    address[][] memory accounts = new address[][](1);
    accounts[0] = new address[](1);
    accounts[0][0] = account;
    vm.prank(OWNER);
    moolah.batchToggleLiquidationWhitelist(ids, accounts, true);
  }

  /// @dev the Liquidated event is the last log of a liquidation.
  function _assertLiquidatedEvent(uint256 seized, uint256 repaid, uint256 repaidShares) internal {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    Vm.Log memory log = logs[logs.length - 1];
    assertEq(log.emitter, address(liquidator), "event emitter");
    assertEq(log.topics[0], OEVLiquidator.Liquidated.selector, "event selector");
    assertEq(log.topics[1], Id.unwrap(id), "event id");
    assertEq(log.topics[2], bytes32(uint256(uint160(address(this)))), "event borrower");
    assertEq(log.data, abi.encode(seized, repaid, repaidShares, ATLAS), "event data");
  }

  function _toLiquidatorParams(MarketParams memory mp) internal pure returns (ILiquidatorMoolah.MarketParams memory) {
    return ILiquidatorMoolah.MarketParams(mp.loanToken, mp.collateralToken, mp.oracle, mp.irm, mp.lltv);
  }
}

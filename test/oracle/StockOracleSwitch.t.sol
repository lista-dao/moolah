// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";

contract StockOracleSwitchTest is Test {
  StockOracleSwitch internal sw;

  // actors
  address internal admin = makeAddr("admin");
  address internal manager = makeAddr("manager");
  address internal bot = makeAddr("bot");
  address internal pauser = makeAddr("pauser");
  address internal stranger = makeAddr("stranger");

  // tokens
  address internal stock = makeAddr("stock");
  address internal usdt = makeAddr("usdt"); // unregistered (loan token)

  // role ids
  bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal MANAGER;
  bytes32 internal BOT;
  bytes32 internal PAUSER;

  // mirror of the events under test
  event StockSet(address indexed token, bool registered);
  event StockEnable(address indexed token, bool enabled);
  event GlobalEnabledSet(bool enabled);

  function setUp() public {
    StockOracleSwitch impl = new StockOracleSwitch();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, admin, manager, bot, pauser)
    );
    sw = StockOracleSwitch(address(proxy));

    MANAGER = sw.MANAGER();
    BOT = sw.BOT();
    PAUSER = sw.PAUSER();
  }

  /// @dev register a stock (which enables it by default) and open the global switch (fully tradable).
  function _openStock(address token) internal {
    vm.prank(manager);
    sw.setStock(token, true); // registers AND enables
    vm.prank(bot);
    sw.setGlobal(true);
  }

  // ----------------------------------------------------------------------
  //                            initialize
  // ----------------------------------------------------------------------

  function test_initialize_grantsRoles() public view {
    assertTrue(sw.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin");
    assertTrue(sw.hasRole(MANAGER, manager), "manager");
    assertTrue(sw.hasRole(BOT, bot), "bot");
    assertTrue(sw.hasRole(PAUSER, pauser), "pauser");
  }

  function test_initialize_globalEnabledDefaultsFalse() public view {
    assertFalse(sw.globalEnabled(), "market should be closed until BOT opens it");
  }

  /// @dev MANAGER administers the BOT role.
  function test_initialize_botRoleAdminIsManager() public view {
    assertEq(sw.getRoleAdmin(BOT), MANAGER, "BOT admin should be MANAGER");
    assertEq(sw.getRoleAdmin(MANAGER), DEFAULT_ADMIN_ROLE, "MANAGER keeps default admin");
    assertEq(sw.getRoleAdmin(PAUSER), DEFAULT_ADMIN_ROLE, "PAUSER keeps default admin");
  }

  function test_initialize_revertsOnZeroAddress() public {
    StockOracleSwitch impl = new StockOracleSwitch();

    vm.expectRevert(StockOracleSwitch.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, address(0), manager, bot, pauser)
    );

    vm.expectRevert(StockOracleSwitch.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, admin, address(0), bot, pauser)
    );

    vm.expectRevert(StockOracleSwitch.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, admin, manager, address(0), pauser)
    );

    vm.expectRevert(StockOracleSwitch.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, admin, manager, bot, address(0))
    );
  }

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert(); // Initializable: InvalidInitialization
    sw.initialize(admin, manager, bot, pauser);
  }

  // ----------------------------------------------------------------------
  //                              isEnabled
  // ----------------------------------------------------------------------

  function test_isEnabled_unregisteredAlwaysEnabled() public {
    // unregistered token passes through (always enabled) regardless of the global switch
    assertTrue(sw.isEnabled(usdt), "unregistered should be enabled while global off");
    vm.prank(bot);
    sw.setGlobal(true);
    assertTrue(sw.isEnabled(usdt), "unregistered should be enabled while global on");
  }

  function test_isEnabled_falseWhileGlobalOff() public {
    vm.prank(manager);
    sw.setStock(stock, true); // registered + enabled, but global still off
    assertFalse(sw.isEnabled(stock), "registered+enabled but global off -> not enabled");
  }

  function test_isEnabled_falseWhileStockDisabled() public {
    vm.prank(manager);
    sw.setStock(stock, true); // registered + enabled
    vm.prank(bot);
    sw.setGlobal(true);
    vm.prank(bot);
    sw.close(stock); // BOT closes this specific stock
    assertFalse(sw.isEnabled(stock), "registered+globalOn but stock disabled -> not enabled");
  }

  function test_isEnabled_trueWhenStockAndGlobalOn() public {
    _openStock(stock);
    assertTrue(sw.isEnabled(stock), "registered + stock on + global on -> enabled");

    // disabling the stock alone makes it not enabled again
    vm.prank(bot);
    sw.close(stock);
    assertFalse(sw.isEnabled(stock), "disabling the stock -> not enabled");
  }

  // ----------------------------------------------------------------------
  //                          setStock (MANAGER)
  // ----------------------------------------------------------------------

  function test_setStock_managerRegistersAndEnablesAndEmits() public {
    // registering both registers and enables, emitting StockSet + StockEnable
    vm.expectEmit(true, false, false, true, address(sw));
    emit StockSet(stock, true);
    vm.expectEmit(true, false, false, true, address(sw));
    emit StockEnable(stock, true);

    vm.prank(manager);
    sw.setStock(stock, true);

    assertTrue(sw.registered(stock), "registered");
    assertTrue(sw.enabled(stock), "registering enables the stock by default");
  }

  function test_setStock_canUnregister() public {
    vm.startPrank(manager);
    sw.setStock(stock, true);
    sw.setStock(stock, false);
    vm.stopPrank();

    assertFalse(sw.registered(stock));
    assertFalse(sw.enabled(stock), "un-registering disables the stock");
    assertTrue(sw.isEnabled(stock), "un-registered token is passthrough again (enabled)");
  }

  function test_setStock_revertsForNonManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
    );
    sw.setStock(stock, true);
  }

  function test_setStock_revertsOnZeroAddress() public {
    vm.prank(manager);
    vm.expectRevert(StockOracleSwitch.ZeroAddress.selector);
    sw.setStock(address(0), true);
  }

  function test_setStock_revertsWhenAlreadySet() public {
    vm.startPrank(manager);
    sw.setStock(stock, true);
    vm.expectRevert(StockOracleSwitch.AlreadySet.selector);
    sw.setStock(stock, true);
    vm.stopPrank();
  }

  // ----------------------------------------------------------------------
  //              open / close (BOT) — registered-only
  // ----------------------------------------------------------------------

  function test_open_botReopensAndEmits() public {
    // register (auto-enabled) then close, so BOT can re-open it
    vm.prank(manager);
    sw.setStock(stock, true);
    vm.prank(bot);
    sw.close(stock);

    vm.expectEmit(true, false, false, true, address(sw));
    emit StockEnable(stock, true);

    vm.prank(bot);
    sw.open(stock);

    assertTrue(sw.enabled(stock));
  }

  function test_open_revertsForNonBot() public {
    vm.prank(manager);
    sw.setStock(stock, true);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, BOT));
    sw.open(stock);
  }

  function test_open_revertsWhenNotRegistered() public {
    vm.prank(bot);
    vm.expectRevert(StockOracleSwitch.NotRegistered.selector);
    sw.open(stock);
  }

  function test_open_revertsWhenAlreadyEnabled() public {
    // registering already enables the stock, so enabling again reverts
    vm.prank(manager);
    sw.setStock(stock, true);
    vm.prank(bot);
    vm.expectRevert(StockOracleSwitch.AlreadySet.selector);
    sw.open(stock);
  }

  function test_close_botClosesAndEmits() public {
    vm.prank(manager);
    sw.setStock(stock, true); // registered + enabled

    vm.expectEmit(true, false, false, true, address(sw));
    emit StockEnable(stock, false);

    vm.prank(bot);
    sw.close(stock);

    assertFalse(sw.enabled(stock));
  }

  function test_close_revertsForNonBot() public {
    vm.prank(manager);
    sw.setStock(stock, true);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, BOT));
    sw.close(stock);
  }

  function test_close_revertsWhenNotRegistered() public {
    vm.prank(bot);
    vm.expectRevert(StockOracleSwitch.NotRegistered.selector);
    sw.close(stock);
  }

  function test_close_revertsWhenAlreadyDisabled() public {
    vm.prank(manager);
    sw.setStock(stock, true); // enabled
    vm.startPrank(bot);
    sw.close(stock); // now disabled
    vm.expectRevert(StockOracleSwitch.AlreadySet.selector);
    sw.close(stock);
    vm.stopPrank();
  }

  // ----------------------------------------------------------------------
  //                          setGlobal (BOT)
  // ----------------------------------------------------------------------

  function test_setGlobal_botTogglesAndEmits() public {
    vm.expectEmit(false, false, false, true, address(sw));
    emit GlobalEnabledSet(true);

    vm.prank(bot);
    sw.setGlobal(true);

    assertTrue(sw.globalEnabled());
  }

  function test_setGlobal_revertsForNonBot() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, BOT));
    sw.setGlobal(true);
  }

  function test_setGlobal_revertsWhenSameValue() public {
    // defaults to false; setting false again must revert
    vm.prank(bot);
    vm.expectRevert(StockOracleSwitch.AlreadySet.selector);
    sw.setGlobal(false);
  }

  // ----------------------------------------------------------------------
  //                       emergencyClose (PAUSER)
  // ----------------------------------------------------------------------

  function test_emergencyClose_pauserForcesClosed() public {
    vm.prank(bot);
    sw.setGlobal(true);
    assertTrue(sw.globalEnabled(), "market open");

    vm.expectEmit(false, false, false, true, address(sw));
    emit GlobalEnabledSet(false);
    vm.prank(pauser);
    sw.emergencyClose();

    assertFalse(sw.globalEnabled(), "emergencyClose forces the market closed");
  }

  function test_emergencyClose_revertsForNonPauser() public {
    vm.prank(bot); // BOT is not PAUSER
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, PAUSER));
    sw.emergencyClose();
  }

  function test_emergencyClose_succeedsWhenAlreadyClosed() public {
    // globalEnabled defaults false; emergencyClose must still succeed (no AlreadySet guard)
    vm.prank(pauser);
    sw.emergencyClose();
    assertFalse(sw.globalEnabled());
  }

  // ----------------------------------------------------------------------
  //          MANAGER administers BOT (grant / revoke)
  // ----------------------------------------------------------------------

  function test_manager_canGrantBot() public {
    address newBot = makeAddr("newBot");
    vm.prank(manager);
    sw.grantRole(BOT, newBot);
    assertTrue(sw.hasRole(BOT, newBot), "manager should be able to grant BOT");
  }

  function test_manager_canRevokeBot() public {
    vm.prank(manager);
    sw.revokeRole(BOT, bot);
    assertFalse(sw.hasRole(BOT, bot), "manager should be able to revoke BOT");
  }

  function test_manager_grantedBotCanOperate() public {
    address newBot = makeAddr("newBot");
    vm.prank(manager);
    sw.grantRole(BOT, newBot);

    vm.prank(newBot);
    sw.setGlobal(true);
    assertTrue(sw.globalEnabled(), "freshly granted BOT can flip the global switch");
  }

  function test_manager_revokedBotCannotOperate() public {
    vm.prank(manager);
    sw.revokeRole(BOT, bot);

    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, BOT));
    sw.setGlobal(true);
  }

  /// @dev DEFAULT_ADMIN can no longer grant BOT directly: BOT's admin is now MANAGER.
  function test_admin_cannotDirectlyGrantBot() public {
    address newBot = makeAddr("newBot");
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, MANAGER));
    sw.grantRole(BOT, newBot);
  }

  /// @dev but DEFAULT_ADMIN keeps indirect control: it admins MANAGER, so it can self-grant MANAGER then manage BOT.
  function test_admin_retainsControlViaManager() public {
    address newBot = makeAddr("newBot");
    vm.startPrank(admin);
    sw.grantRole(MANAGER, admin);
    sw.grantRole(BOT, newBot);
    vm.stopPrank();
    assertTrue(sw.hasRole(BOT, newBot), "admin can still reach BOT through MANAGER");
  }

  /// @dev MANAGER must not be able to grant MANAGER (its admin is still DEFAULT_ADMIN_ROLE).
  function test_manager_cannotGrantManager() public {
    vm.prank(manager);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, DEFAULT_ADMIN_ROLE)
    );
    sw.grantRole(MANAGER, stranger);
  }

  // ----------------------------------------------------------------------
  //                          _authorizeUpgrade
  // ----------------------------------------------------------------------

  function test_upgrade_revertsForNonAdmin() public {
    address newImpl = address(new StockOracleSwitch());
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
    );
    sw.upgradeToAndCall(newImpl, "");
  }

  function test_upgrade_succeedsForAdmin() public {
    vm.prank(manager);
    sw.setStock(stock, true);

    address newImpl = address(new StockOracleSwitch());
    vm.prank(admin);
    sw.upgradeToAndCall(newImpl, "");

    // state survives the upgrade
    assertTrue(sw.registered(stock), "registered state preserved across upgrade");
  }
}

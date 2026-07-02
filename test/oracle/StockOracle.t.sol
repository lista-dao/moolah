// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { StockOracle } from "../../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { TokenConfig } from "../../src/moolah/interfaces/IOracle.sol";

contract StockOracleTest is Test {
  StockOracle internal oracle;
  StockOracleSwitch internal stockSwitch;
  OracleMock internal resilient;

  // actors (shared MANAGER/admin across both contracts; bot only matters for the switch)
  address internal admin = makeAddr("admin");
  address internal manager = makeAddr("manager");
  address internal bot = makeAddr("bot");
  address internal pauser = makeAddr("pauser");
  address internal stranger = makeAddr("stranger");

  // tokens
  address internal stock = makeAddr("stock"); // a managed bStock
  address internal usdt = makeAddr("usdt"); // unregistered loan token (passthrough)

  uint256 internal constant STOCK_PRICE = 150e8;
  uint256 internal constant USDT_PRICE = 1e8;

  bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal MANAGER;

  event StockSwitchSet(address indexed stockSwitch);
  event ResilientOracleSet(address indexed resilientOracle);

  function setUp() public {
    // resilient (Atlas-backed) oracle mock
    resilient = new OracleMock();
    resilient.setPrice(stock, STOCK_PRICE);
    resilient.setPrice(usdt, USDT_PRICE);

    // real market switch
    StockOracleSwitch swImpl = new StockOracleSwitch();
    ERC1967Proxy swProxy = new ERC1967Proxy(
      address(swImpl),
      abi.encodeWithSelector(StockOracleSwitch.initialize.selector, admin, manager, bot, pauser)
    );
    stockSwitch = StockOracleSwitch(address(swProxy));

    // oracle under test
    StockOracle oImpl = new StockOracle();
    ERC1967Proxy oProxy = new ERC1967Proxy(
      address(oImpl),
      abi.encodeWithSelector(StockOracle.initialize.selector, admin, manager, address(stockSwitch), address(resilient))
    );
    oracle = StockOracle(address(oProxy));

    MANAGER = oracle.MANAGER();
  }

  /// @dev register a stock (which enables it by default) and open the global switch (fully tradable).
  function _openStock(address token) internal {
    vm.prank(manager);
    stockSwitch.setStock(token, true); // registers AND enables
    vm.prank(manager);
    stockSwitch.setGlobal(true);
  }

  // ----------------------------------------------------------------------
  //                            initialize
  // ----------------------------------------------------------------------

  function test_initialize_setsState() public view {
    assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin");
    assertTrue(oracle.hasRole(MANAGER, manager), "manager");
    assertEq(address(oracle.stockSwitch()), address(stockSwitch), "switch");
    assertEq(oracle.resilientOracle(), address(resilient), "resilient");
  }

  function test_initialize_revertsOnZeroAddress() public {
    StockOracle impl = new StockOracle();

    vm.expectRevert(StockOracle.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        StockOracle.initialize.selector,
        address(0),
        manager,
        address(stockSwitch),
        address(resilient)
      )
    );

    vm.expectRevert(StockOracle.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        StockOracle.initialize.selector,
        admin,
        address(0),
        address(stockSwitch),
        address(resilient)
      )
    );

    vm.expectRevert(StockOracle.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracle.initialize.selector, admin, manager, address(0), address(resilient))
    );

    vm.expectRevert(StockOracle.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(StockOracle.initialize.selector, admin, manager, address(stockSwitch), address(0))
    );
  }

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert(); // Initializable: InvalidInitialization
    oracle.initialize(admin, manager, address(stockSwitch), address(resilient));
  }

  // ----------------------------------------------------------------------
  //                               peek
  // ----------------------------------------------------------------------

  function test_peek_unregisteredPassesThrough() public view {
    // usdt is not registered in the switch -> never gated, even with the market closed
    assertEq(oracle.peek(usdt), USDT_PRICE, "unregistered token should pass through to resilient price");
  }

  function test_peek_registeredOpenReturnsResilientPrice() public {
    _openStock(stock);
    assertEq(oracle.peek(stock), STOCK_PRICE, "open stock should return resilient price");
  }

  function test_peek_revertsWhenGlobalOff() public {
    vm.prank(manager);
    stockSwitch.setStock(stock, true); // registered + enabled, but global still off

    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    oracle.peek(stock);
  }

  function test_peek_revertsWhenStockDisabled() public {
    vm.prank(manager);
    stockSwitch.setStock(stock, true); // registered + enabled
    vm.prank(manager);
    stockSwitch.setGlobal(true);
    vm.prank(bot);
    stockSwitch.close(stock); // market open, but the stock itself is disabled

    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    oracle.peek(stock);
  }

  function test_peek_revertsAfterStockDisabled() public {
    _openStock(stock);
    assertEq(oracle.peek(stock), STOCK_PRICE);

    vm.prank(bot);
    stockSwitch.close(stock);

    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    oracle.peek(stock);
  }

  // ----------------------------------------------------------------------
  //                          getTokenConfig
  // ----------------------------------------------------------------------

  function test_getTokenConfig_delegatesToResilient() public view {
    TokenConfig memory cfg = oracle.getTokenConfig(usdt);
    assertEq(cfg.asset, usdt, "config asset");
  }

  function test_getTokenConfig_notGatedBySwitch() public {
    // even a registered + closed stock returns its config (only peek is gated)
    vm.prank(manager);
    stockSwitch.setStock(stock, true); // registered, global off -> peek would revert

    TokenConfig memory cfg = oracle.getTokenConfig(stock);
    assertEq(cfg.asset, stock, "getTokenConfig must not be gated by the switch");
  }

  // ----------------------------------------------------------------------
  //                    setStockSwitch (MANAGER)
  // ----------------------------------------------------------------------

  function test_setStockSwitch_managerSetsAndEmits() public {
    address newSwitch = makeAddr("newSwitch");

    vm.expectEmit(true, false, false, true, address(oracle));
    emit StockSwitchSet(newSwitch);

    vm.prank(manager);
    oracle.setStockSwitch(newSwitch);

    assertEq(address(oracle.stockSwitch()), newSwitch);
  }

  function test_setStockSwitch_revertsForNonManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
    );
    oracle.setStockSwitch(makeAddr("newSwitch"));
  }

  function test_setStockSwitch_revertsOnZeroAddress() public {
    vm.prank(manager);
    vm.expectRevert(StockOracle.ZeroAddress.selector);
    oracle.setStockSwitch(address(0));
  }

  function test_setStockSwitch_revertsWhenAlreadySet() public {
    vm.prank(manager);
    vm.expectRevert(StockOracle.AlreadySet.selector);
    oracle.setStockSwitch(address(stockSwitch));
  }

  // ----------------------------------------------------------------------
  //                  setResilientOracle (MANAGER)
  // ----------------------------------------------------------------------

  function test_setResilientOracle_managerSetsAndEmits() public {
    OracleMock newResilient = new OracleMock();

    vm.expectEmit(true, false, false, true, address(oracle));
    emit ResilientOracleSet(address(newResilient));

    vm.prank(manager);
    oracle.setResilientOracle(address(newResilient));

    assertEq(oracle.resilientOracle(), address(newResilient));
  }

  function test_setResilientOracle_repointChangesPrice() public {
    OracleMock newResilient = new OracleMock();
    newResilient.setPrice(usdt, 2e8); // different price

    vm.prank(manager);
    oracle.setResilientOracle(address(newResilient));

    assertEq(oracle.peek(usdt), 2e8, "peek should use the new resilient oracle");
  }

  function test_setResilientOracle_revertsForNonManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
    );
    oracle.setResilientOracle(makeAddr("newResilient"));
  }

  function test_setResilientOracle_revertsOnZeroAddress() public {
    vm.prank(manager);
    vm.expectRevert(StockOracle.ZeroAddress.selector);
    oracle.setResilientOracle(address(0));
  }

  function test_setResilientOracle_revertsWhenAlreadySet() public {
    vm.prank(manager);
    vm.expectRevert(StockOracle.AlreadySet.selector);
    oracle.setResilientOracle(address(resilient));
  }

  // ----------------------------------------------------------------------
  //                          _authorizeUpgrade
  // ----------------------------------------------------------------------

  function test_upgrade_revertsForNonAdmin() public {
    address newImpl = address(new StockOracle());
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
    );
    oracle.upgradeToAndCall(newImpl, "");
  }

  function test_upgrade_succeedsForAdmin() public {
    address newImpl = address(new StockOracle());
    vm.prank(admin);
    oracle.upgradeToAndCall(newImpl, "");
    // state survives the upgrade
    assertEq(oracle.resilientOracle(), address(resilient), "state preserved across upgrade");
  }
}

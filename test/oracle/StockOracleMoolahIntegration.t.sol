// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { StockOracle } from "../../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";

/// @dev I11 (HashDit audit): integration tests wiring StockOracle + StockOracleSwitch into Moolah market flows.
///      The collateral token is a managed bStock gated by the switch; the loan token is unregistered (passthrough).
///      Covers closed-market gating (borrow / liquidate revert), non-price actions surviving a close
///      (repay / supplyCollateral), open-market happy paths, createMarket gating, and the PR #196 MANAGER/BOT split.
contract StockOracleMoolahIntegrationTest is BaseTest {
  using MarketParamsLib for MarketParams;

  StockOracle internal stockOracle;
  StockOracleSwitch internal stockSwitch;

  MarketParams internal stockMarket;
  Id internal stockId;

  address internal STOCK_MANAGER = makeAddr("StockManager");
  address internal STOCK_BOT = makeAddr("StockBot");
  address internal STOCK_PAUSER = makeAddr("StockPauser");

  uint256 internal constant SUPPLY_LIQUIDITY = 1_000e18;
  uint256 internal constant COLLATERAL = 100e18;

  function setUp() public override {
    super.setUp();

    // switch: admin=OWNER, manager=STOCK_MANAGER, bot=STOCK_BOT, pauser=STOCK_PAUSER
    StockOracleSwitch swImpl = new StockOracleSwitch();
    stockSwitch = StockOracleSwitch(
      address(
        new ERC1967Proxy(
          address(swImpl),
          abi.encodeWithSelector(StockOracleSwitch.initialize.selector, OWNER, STOCK_MANAGER, STOCK_BOT, STOCK_PAUSER)
        )
      )
    );

    // stock oracle delegates pricing to the BaseTest OracleMock (`oracle`) as the resilient (Atlas) feed
    StockOracle soImpl = new StockOracle();
    stockOracle = StockOracle(
      address(
        new ERC1967Proxy(
          address(soImpl),
          abi.encodeWithSelector(
            StockOracle.initialize.selector,
            OWNER,
            STOCK_MANAGER,
            address(stockSwitch),
            address(oracle)
          )
        )
      )
    );

    // register the collateral token as a managed stock and open the market (global + per-stock)
    vm.startPrank(STOCK_MANAGER);
    stockSwitch.setStock(address(collateralToken), true); // registers and enables the per-stock flag
    stockSwitch.setGlobal(true); // MANAGER opens the global market switch
    vm.stopPrank();
    assertTrue(stockSwitch.isEnabled(address(collateralToken)), "stock should be open after setup");

    // create the stock-collateral market with StockOracle as the market oracle (peeks succeed while open)
    stockMarket = MarketParams(
      address(loanToken),
      address(collateralToken),
      address(stockOracle),
      address(irm),
      DEFAULT_TEST_LLTV
    );
    stockId = stockMarket.id();
    vm.prank(OWNER);
    moolah.createMarket(stockMarket);

    _forward(1);
  }

  /* ------------------------------------------------------------------ helpers */

  function _closeStock() internal {
    vm.prank(STOCK_BOT);
    stockSwitch.close(address(collateralToken));
    assertFalse(stockSwitch.isEnabled(address(collateralToken)), "stock should be closed");
  }

  /// @dev seed loan liquidity + a borrow position for BORROWER while the market is open.
  function _seedBorrow(uint256 borrowAmt) internal {
    loanToken.setBalance(SUPPLIER, SUPPLY_LIQUIDITY);
    vm.prank(SUPPLIER);
    moolah.supply(stockMarket, SUPPLY_LIQUIDITY, 0, SUPPLIER, hex"");

    collateralToken.setBalance(BORROWER, COLLATERAL);
    vm.startPrank(BORROWER);
    moolah.supplyCollateral(stockMarket, COLLATERAL, BORROWER, hex"");
    moolah.borrow(stockMarket, borrowAmt, 0, BORROWER, BORROWER);
    vm.stopPrank();
  }

  /* ---------------------------------------------- switch CLOSED: price actions revert */

  function test_borrow_revertsWhenClosed() public {
    _seedBorrow(10e18);
    _closeStock();

    // health check peeks the (closed) collateral -> reverts
    vm.prank(BORROWER);
    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    moolah.borrow(stockMarket, 1e18, 0, BORROWER, BORROWER);
  }

  function test_liquidate_revertsWhenClosed() public {
    _seedBorrow(79e18); // near max (maxBorrow = 100 * 0.8 = 80)
    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 2); // now unhealthy
    assertFalse(_isHealthy(stockMarket, BORROWER), "position should be unhealthy");

    _closeStock();

    loanToken.setBalance(LIQUIDATOR, SUPPLY_LIQUIDITY);
    vm.prank(LIQUIDATOR);
    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    moolah.liquidate(stockMarket, BORROWER, COLLATERAL, 0, hex"");
  }

  /* ------------------------------------------ switch CLOSED: non-price actions still work */

  function test_repay_succeedsWhenClosed() public {
    _seedBorrow(50e18);
    _closeStock();

    uint256 sharesBefore = moolah.position(stockId, BORROWER).borrowShares;
    vm.prank(BORROWER);
    moolah.repay(stockMarket, 10e18, 0, BORROWER, hex"");
    assertLt(moolah.position(stockId, BORROWER).borrowShares, sharesBefore, "repay should reduce debt while closed");
  }

  function test_supplyCollateral_succeedsWhenClosed() public {
    _closeStock();

    collateralToken.setBalance(BORROWER, COLLATERAL);
    vm.prank(BORROWER);
    moolah.supplyCollateral(stockMarket, COLLATERAL, BORROWER, hex"");
    assertEq(moolah.position(stockId, BORROWER).collateral, COLLATERAL, "collateral should be recorded while closed");
  }

  /* ------------------------------------------------------ switch OPEN: happy paths */

  function test_borrow_succeedsWhenOpen() public {
    _seedBorrow(50e18);
    assertGt(moolah.position(stockId, BORROWER).borrowShares, 0, "borrow should succeed while open");
  }

  function test_liquidate_succeedsWhenOpen() public {
    _seedBorrow(79e18);
    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE / 2);
    assertFalse(_isHealthy(stockMarket, BORROWER), "position should be unhealthy");

    loanToken.setBalance(LIQUIDATOR, SUPPLY_LIQUIDITY);
    vm.prank(LIQUIDATOR);
    moolah.liquidate(stockMarket, BORROWER, COLLATERAL, 0, hex""); // seize all collateral
    assertEq(moolah.position(stockId, BORROWER).collateral, 0, "collateral should be seized while open");
  }

  /* -------------------------------------------------------- createMarket gating */

  function test_createMarket_revertsWhenClosedCollateral() public {
    uint256 lltv = 0.5 ether;
    vm.prank(OWNER);
    moolah.enableLltv(lltv);

    _closeStock();

    MarketParams memory m = MarketParams(
      address(loanToken),
      address(collateralToken),
      address(stockOracle),
      address(irm),
      lltv
    );
    vm.prank(OWNER);
    vm.expectRevert(StockOracle.StockMarketClosed.selector);
    moolah.createMarket(m);
  }

  function test_createMarket_succeedsWhenOpenCollateral() public {
    uint256 lltv = 0.5 ether;
    vm.prank(OWNER);
    moolah.enableLltv(lltv);

    MarketParams memory m = MarketParams(
      address(loanToken),
      address(collateralToken),
      address(stockOracle),
      address(irm),
      lltv
    );
    vm.prank(OWNER);
    moolah.createMarket(m); // stock is open (from setUp) -> both peeks succeed
    assertGt(moolah.market(m.id()).lastUpdate, 0, "market should be created while open");
  }

  /* ------------------------------------------------------ PR #196 role split */

  function test_roleSplit_botCannotSetGlobal() public {
    bytes32 managerRole = stockSwitch.MANAGER(); // read before prank so it isn't consumed by this call
    vm.prank(STOCK_BOT);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STOCK_BOT, managerRole)
    );
    stockSwitch.setGlobal(false);
  }

  function test_roleSplit_managerCannotBatchSetStatus() public {
    bytes32 botRole = stockSwitch.BOT(); // read before prank so it isn't consumed by this call
    address[] memory toks = new address[](1);
    toks[0] = address(collateralToken);
    vm.prank(STOCK_MANAGER);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STOCK_MANAGER, botRole)
    );
    stockSwitch.batchSetStatus(toks, false);
  }
}

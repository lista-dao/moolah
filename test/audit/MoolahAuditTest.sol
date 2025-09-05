// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { IrmMock } from "moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { Moolah } from "moolah/Moolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";

contract MoolahAuditTest is Test {
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;

  address internal SUPPLIER;
  address internal BORROWER;
  address internal REPAYER;
  address internal ONBEHALF;
  address internal RECEIVER;
  address internal LIQUIDATOR;
  address internal OWNER;
  address internal FEE_RECIPIENT;
  address internal DEFAULT_ADMIN;

  IMoolah internal moolah;
  ERC20Mock internal loanToken;
  ERC20Mock internal collateralToken;
  OracleMock internal oracle;
  IrmMock internal irm;

  MarketParams internal marketParams;
  Id internal id;

  uint256 internal constant DEFAULT_PRICE = 1e8;
  uint256 internal constant MIN_LOAN_VALUE = 15 * 1e8;
  uint256 internal constant DEFAULT_TEST_LLTV = 0.8 ether;

  function setUp() public {
    SUPPLIER = makeAddr("Supplier");
    BORROWER = makeAddr("Borrower");
    REPAYER = makeAddr("Repayer");
    ONBEHALF = makeAddr("OnBehalf");
    RECEIVER = makeAddr("Receiver");
    LIQUIDATOR = makeAddr("Liquidator");
    OWNER = makeAddr("Owner");
    FEE_RECIPIENT = makeAddr("FeeRecipient");
    oracle = new OracleMock();

    moolah = newMoolah(OWNER, OWNER, OWNER, MIN_LOAN_VALUE);

    loanToken = new ERC20Mock();
    vm.label(address(loanToken), "LoanToken");

    collateralToken = new ERC20Mock();
    vm.label(address(collateralToken), "CollateralToken");

    oracle.setPrice(address(collateralToken), DEFAULT_PRICE);
    oracle.setPrice(address(loanToken), DEFAULT_PRICE);

    irm = new IrmMock();

    marketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_TEST_LLTV
    });

    id = marketParams.id();

    vm.startPrank(OWNER);
    moolah.enableIrm(address(irm));
    moolah.enableLltv(DEFAULT_TEST_LLTV);

    moolah.createMarket(marketParams);
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(BORROWER);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(REPAYER);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(LIQUIDATOR);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(ONBEHALF);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    moolah.setAuthorization(BORROWER, true);
    vm.stopPrank();
  }

  function test_liquidateWithBadDebt() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    loanToken.setBalance(LIQUIDATOR, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 100 ether, BORROWER, "");
    moolah.borrow(marketParams, 80 ether, 0, BORROWER, BORROWER);
    vm.stopPrank();

    // bad debt
    oracle.setPrice(address(collateralToken), 0.8e8);

    vm.startPrank(LIQUIDATOR);
    vm.expectRevert(bytes(ErrorsLib.UNHEALTHY_POSITION));
    moolah.liquidate(marketParams, BORROWER, 100 ether - 1, 0, "");
    vm.stopPrank();
  }

  function test_createMarketCheck() public {
    vm.startPrank(OWNER);

    // zero loan token
    marketParams.loanToken = address(0);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.createMarket(marketParams);

    // zero collateral token
    marketParams.loanToken = address(loanToken);
    marketParams.collateralToken = address(0);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.createMarket(marketParams);

    // zero oracle
    marketParams.collateralToken = address(collateralToken);
    marketParams.oracle = address(0);
    vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
    moolah.createMarket(marketParams);

    // fake oracle
    marketParams.oracle = address(1);
    vm.expectRevert();
    moolah.createMarket(marketParams);
    vm.stopPrank();
  }

  function test_inflatingBorrowShares() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    loanToken.setBalance(LIQUIDATOR, 100 ether);
    collateralToken.setBalance(BORROWER, 100 ether);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 100 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(marketParams, 100 ether, BORROWER, "");
    vm.expectRevert(bytes(ErrorsLib.REMAIN_BORROW_TOO_LOW));
    moolah.borrow(marketParams, 1e6 - 1, 0, BORROWER, BORROWER);
    vm.stopPrank();
  }

  function test_createMarketFee() public {
    ERC20Mock testLoan = new ERC20Mock();
    ERC20Mock testCollateral = new ERC20Mock();

    MarketParams memory testMarketParams = MarketParams({
      loanToken: address(testLoan),
      collateralToken: address(testCollateral),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_TEST_LLTV
    });

    moolah.createMarket(testMarketParams);

    Id marketId = testMarketParams.id();
    uint128 fee = moolah.market(marketId).fee;
    assertTrue(fee == 0, "fee should be 0");
  }

  function test_supplyLessThanMinLoanValue() public {
    loanToken.setBalance(SUPPLIER, 100 ether);

    vm.startPrank(SUPPLIER);
    vm.expectRevert(bytes(ErrorsLib.REMAIN_SUPPLY_TOO_LOW));
    moolah.supply(marketParams, MIN_LOAN_VALUE - 1, 0, SUPPLIER, "");
    vm.stopPrank();
  }

  function newMoolah(address admin, address manager, address pauser, uint256 minLoanValue) internal returns (IMoolah) {
    Moolah moolahImpl = new Moolah();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, minLoanValue)
    );

    return IMoolah(address(moolahProxy));
  }
}

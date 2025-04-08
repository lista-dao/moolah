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
import { Liquidator } from "liquidator/Liquidator.sol";
import { ILiquidator } from "liquidator/ILiquidator.sol";
import { MockOneInch } from "../liquidator/mocks/MockOneInch.sol";

contract LiquidatorAuditTest is Test {
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;

  error NotWhitelisted();

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
  ILiquidator internal liquidator;
  MockOneInch oneInch;

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
    liquidator = newLiquidator(OWNER, OWNER, LIQUIDATOR, address(moolah));
    oneInch = new MockOneInch();

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

  function test_liquidateFakeMarket() public {
    ERC20Mock fakeLoanToken = new ERC20Mock();
    ERC20Mock fakeCollateralToken = new ERC20Mock();

    MarketParams memory fakeMarketParams = MarketParams({
      loanToken: address(fakeLoanToken),
      collateralToken: address(fakeCollateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_TEST_LLTV
    });

    moolah.createMarket(fakeMarketParams);

    Id fakeId = fakeMarketParams.id();

    oracle.setPrice(address(fakeLoanToken), 1e8);
    oracle.setPrice(address(fakeCollateralToken), 1e8);

    fakeLoanToken.setBalance(SUPPLIER, 100 ether);
    fakeCollateralToken.setBalance(BORROWER, 100 ether);

    vm.startPrank(SUPPLIER);
    fakeLoanToken.approve(address(moolah), type(uint256).max);
    moolah.supply(fakeMarketParams, 100 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROWER);
    fakeCollateralToken.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(fakeMarketParams, 100 ether, BORROWER, "");
    moolah.borrow(fakeMarketParams, 80 ether, 0, BORROWER, BORROWER);
    vm.stopPrank();

    oracle.setPrice(address(fakeCollateralToken), 0.5e8);

    vm.startPrank(LIQUIDATOR);
    fakeLoanToken.approve(address(moolah), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector));
    liquidator.liquidate(Id.unwrap(fakeId), BORROWER, 100 ether, 0);
    vm.stopPrank();
  }

  function test_fakePair() public {
    vm.startPrank(OWNER);
    liquidator.setTokenWhitelist(address(loanToken), true);
    liquidator.setTokenWhitelist(address(collateralToken), true);
    liquidator.setMarketWhitelist(Id.unwrap(id), true);
    vm.stopPrank();

    ERC20Mock fakePair = new ERC20Mock();

    vm.startPrank(LIQUIDATOR);
    vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector));
    liquidator.sellToken(
      address(fakePair),
      address(collateralToken),
      address(loanToken),
      100 ether,
      0,
      abi.encodeWithSelector(ERC20Mock.approve.selector, LIQUIDATOR, type(uint256).max));

    vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector));
    liquidator.flashLiquidate(
      Id.unwrap(id),
      BORROWER, 100 ether,
      address(fakePair),
      abi.encodeWithSelector(ERC20Mock.approve.selector, LIQUIDATOR, type(uint256).max));
    vm.stopPrank();
  }

  function test_approveAfterSwap() public {
    vm.startPrank(OWNER);
    liquidator.setTokenWhitelist(address(loanToken), true);
    liquidator.setTokenWhitelist(address(collateralToken), true);
    liquidator.setMarketWhitelist(Id.unwrap(id), true);
    liquidator.setPairWhitelist(address(oneInch), true);
    vm.stopPrank();

    uint256 loanAmount = 100 ether;
    uint256 collateralAmount = 100 ether;

    oracle.setPrice(address(collateralToken), 1e8);
    oracle.setPrice(address(loanToken), 1e8);

    loanToken.setBalance(address(this), loanAmount);
    collateralToken.setBalance(address(this), collateralAmount);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);

    moolah.supply(marketParams, loanAmount, 0, address(this), "");

    moolah.supplyCollateral(marketParams, collateralAmount, address(this), "");

    moolah.borrow(marketParams, 80 ether, 0, address(this), address(this));

    oracle.setPrice(address(collateralToken), 0.5e8);

    vm.startPrank(LIQUIDATOR);
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
        50 ether
      )
    );
    vm.stopPrank();

    assertEq(collateralToken.allowance(address(liquidator), address(oneInch)), 0, "collateralToken allowance should be 0");
  }

  function newMoolah(address admin, address manager, address pauser, uint256 minLoanValue) internal returns (IMoolah) {
    Moolah moolahImpl = new Moolah();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, minLoanValue)
    );

    return IMoolah(address(moolahProxy));
  }

  function newLiquidator(address admin, address manager, address bot, address _moolah) internal returns (ILiquidator) {
    Liquidator impl = new Liquidator(_moolah);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager, bot)
    );
    return ILiquidator(address(proxy));
  }
}

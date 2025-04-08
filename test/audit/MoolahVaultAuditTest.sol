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
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { IMoolahVault } from "moolah-vault/interfaces/IMoolahVault.sol";
import { ErrorsLib } from "moolah-vault/libraries/ErrorsLib.sol";

contract MoolahVaultAuditTest is Test {
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
  IMoolahVault vault;

  MarketParams internal marketParams;
  Id internal id;

  uint256 internal constant DEFAULT_PRICE = 1e8;
  uint256 internal constant MIN_LOAN_VALUE = 15 * 1e8;
  uint256 internal constant DEFAULT_TEST_LLTV = 0.8 ether;
  bytes32 public constant CURATOR_ROLE = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR"); // manager role

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

    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = id;
    vault = newMoolahVault(OWNER, OWNER, address(moolah), address(loanToken), "Moolah Vault", "MVLT");
    vm.startPrank(OWNER);
    vault.grantRole(CURATOR_ROLE, OWNER);
    vault.grantRole(ALLOCATOR_ROLE, OWNER);
    vault.setCap(marketParams, type(uint128).max);
    vault.setSupplyQueue(supplyQueue);
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    loanToken.approve(address(vault), type(uint256).max);
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

  function newMoolah(address admin, address manager, address pauser, uint256 minLoanValue) internal returns (IMoolah) {
    Moolah moolahImpl = new Moolah();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, minLoanValue)
    );

    return IMoolah(address(moolahProxy));
  }

  function test_supplyVaultLessThanMinLoanValue() public {
    loanToken.setBalance(SUPPLIER, 100 ether);

    vm.startPrank(SUPPLIER);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AllCapsReached.selector));
    vault.deposit(MIN_LOAN_VALUE - 1, SUPPLIER);
    vm.stopPrank();
  }

  function newMoolahVault(
    address admin,
    address manager,
    address _moolah,
    address _asset,
    string memory _name,
    string memory _symbol
  ) internal returns (IMoolahVault) {
    MoolahVault moolahVaultImpl = new MoolahVault(_moolah, _asset);
    ERC1967Proxy moolahVaultProxy = new ERC1967Proxy(
      address(moolahVaultImpl),
      abi.encodeWithSelector(moolahVaultImpl.initialize.selector, admin, manager, _asset, _name, _symbol)
    );

    return IMoolahVault(address(moolahVaultProxy));
  }

}

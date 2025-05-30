// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { Moolah } from "moolah/Moolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { IMoolahVault } from "moolah-vault/interfaces/IMoolahVault.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { LendingFeeRecipient } from "revenue/LendingFeeRecipient.sol";

contract LendingFeeRecipientTest is Test {
  using MarketParamsLib for MarketParams;
  IMoolah moolah;
  IMoolahVault vault;

  address OWNER;
  address BOT;
  address SUPPLIER;
  address BORROW;
  address MARKET_FEE_RECEIVER;
  address VAULT_FEE_RECEIVER;

  address irm;
  uint256 lltv = 80 * 1e16;
  OracleMock oracle;
  MarketParams marketParams;
  Id id;
  LendingFeeRecipient lendingFeeRecipient;

  ERC20Mock internal loanToken;
  ERC20Mock internal collateralToken;

  bytes32 public constant CURATOR_ROLE = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR"); // manager role

  function setUp() public {
    OWNER = makeAddr("OWNER");
    BOT = makeAddr("BOT");
    SUPPLIER = makeAddr("SUPPLIER");
    BORROW = makeAddr("BORROW");
    MARKET_FEE_RECEIVER = makeAddr("MARKET_FEE_RECEIVER");
    VAULT_FEE_RECEIVER = makeAddr("VAULT_FEE_RECEIVER");

    loanToken = new ERC20Mock();
    collateralToken = new ERC20Mock();
    oracle = new OracleMock();

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    moolah = newMoolah(OWNER, OWNER, OWNER);
    vault = newMoolahVault(OWNER, OWNER, address(moolah), address(loanToken), "A", "A");
    irm = address(new InterestRateModel(address(moolah)));
    lendingFeeRecipient = newLendingFeeRecipient(
      address(moolah),
      OWNER,
      OWNER,
      BOT,
      MARKET_FEE_RECEIVER,
      VAULT_FEE_RECEIVER
    );

    vm.startPrank(OWNER);
    moolah.enableLltv(lltv);
    moolah.enableIrm(irm);
    moolah.setFeeRecipient(address(lendingFeeRecipient));

    vault.grantRole(CURATOR_ROLE, OWNER);
    vault.grantRole(ALLOCATOR_ROLE, OWNER);

    vault.setFeeRecipient(address(lendingFeeRecipient));
    vault.setFee(1e17);
    vm.stopPrank();

    marketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: irm,
      lltv: lltv
    });
    id = marketParams.id();
    moolah.createMarket(marketParams);

    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = id;

    vm.startPrank(OWNER);
    vault.setCap(marketParams, type(uint128).max);
    vault.setSupplyQueue(supplyQueue);
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    loanToken.approve(address(moolah), type(uint256).max);
    loanToken.approve(address(vault), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(BORROW);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();
  }

  function test_claimMarketFee() public {
    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROW, 100 ether);
    loanToken.setBalance(BORROW, 100 ether);

    vm.startPrank(SUPPLIER);
    moolah.supply(marketParams, 10 ether, 0, SUPPLIER, "");
    vm.stopPrank();

    vm.startPrank(BORROW);
    moolah.supplyCollateral(marketParams, 100 ether, BORROW, "");
    moolah.borrow(marketParams, 9.1 ether, 0, BORROW, BORROW);
    vm.stopPrank();

    skip(365 days);

    Position memory position = moolah.position(marketParams.id(), BORROW);
    vm.startPrank(BORROW);
    moolah.repay(marketParams, 0, position.borrowShares, BORROW, "");
    vm.stopPrank();

    Position memory feePosition = moolah.position(marketParams.id(), address(lendingFeeRecipient));
    assertTrue(feePosition.supplyShares > 0, "supply shares not minted to fee recipient");

    Id[] memory ids = new Id[](1);
    ids[0] = id;
    vm.startPrank(BOT);
    lendingFeeRecipient.claimMarketFee(ids);
    vm.stopPrank();

    assertTrue(loanToken.balanceOf(MARKET_FEE_RECEIVER) > 0, "market fee not claimed");
  }

  function test_addRemoveVault() public {
    address vault1 = makeAddr("VAULT1");
    address vault2 = makeAddr("VAULT2");
    address vault3 = makeAddr("VAULT3");

    vm.startPrank(OWNER);
    lendingFeeRecipient.addVault(vault1);
    lendingFeeRecipient.addVault(vault2);
    lendingFeeRecipient.addVault(vault3);

    vm.expectRevert(bytes("vault already exists"));
    lendingFeeRecipient.addVault(vault3);

    assertTrue(lendingFeeRecipient.vaults(0) == vault1, "vault1 error");
    assertTrue(lendingFeeRecipient.vaults(1) == vault2, "vault2 error");
    assertTrue(lendingFeeRecipient.vaults(2) == vault3, "vault3 error");

    assertTrue(lendingFeeRecipient.getVaults().length == 3, "vault count not 3");
    lendingFeeRecipient.removeVault(vault2);
    assertTrue(lendingFeeRecipient.getVaults().length == 2, "vault count not 2");
    assertTrue(lendingFeeRecipient.vaults(0) == vault1, "vault1 error");
    assertTrue(lendingFeeRecipient.vaults(1) == vault3, "vault3 error");

    lendingFeeRecipient.removeVault(vault1);
    assertTrue(lendingFeeRecipient.getVaults().length == 1, "vault count not 1");
    assertTrue(lendingFeeRecipient.vaults(0) == vault3, "vault3 error");

    lendingFeeRecipient.removeVault(vault3);
    assertTrue(lendingFeeRecipient.getVaults().length == 0, "vault count not 0");

    vm.stopPrank();

  }

  function test_claimVaultFee() public {
    vm.startPrank(OWNER);
    lendingFeeRecipient.addVault(address(vault));
    vm.stopPrank();

    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROW, 100 ether);
    loanToken.setBalance(BORROW, 100 ether);

    vm.startPrank(SUPPLIER);
    vault.deposit(10 ether, SUPPLIER);
    vm.stopPrank();

    vm.startPrank(BORROW);
    moolah.supplyCollateral(marketParams, 100 ether, BORROW, "");
    moolah.borrow(marketParams, 9.1 ether, 0, BORROW, BORROW);
    vm.stopPrank();

    skip(365 days);

    Position memory position = moolah.position(marketParams.id(), BORROW);
    vm.startPrank(BORROW);
    moolah.repay(marketParams, 0, position.borrowShares, BORROW, "");
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    vault.redeem(vault.balanceOf(SUPPLIER), SUPPLIER, SUPPLIER);
    vm.stopPrank();

    uint256 feeShares = vault.balanceOf(address(lendingFeeRecipient));
    assertTrue(feeShares > 0, "fee shares not minted to fee recipient");

    vm.startPrank(BOT);
    lendingFeeRecipient.claimVaultFee();
    vm.stopPrank();

    assertTrue(loanToken.balanceOf(VAULT_FEE_RECEIVER) > 0, "vault fee not claimed");

  }

  function test_claimVaultFeeForGivenVaults() public {

    loanToken.setBalance(SUPPLIER, 100 ether);
    collateralToken.setBalance(BORROW, 100 ether);
    loanToken.setBalance(BORROW, 100 ether);

    vm.startPrank(SUPPLIER);
    vault.deposit(10 ether, SUPPLIER);
    vm.stopPrank();

    vm.startPrank(BORROW);
    moolah.supplyCollateral(marketParams, 100 ether, BORROW, "");
    moolah.borrow(marketParams, 9.1 ether, 0, BORROW, BORROW);
    vm.stopPrank();

    skip(365 days);

    Position memory position = moolah.position(marketParams.id(), BORROW);
    vm.startPrank(BORROW);
    moolah.repay(marketParams, 0, position.borrowShares, BORROW, "");
    vm.stopPrank();

    vm.startPrank(SUPPLIER);
    vault.redeem(vault.balanceOf(SUPPLIER), SUPPLIER, SUPPLIER);
    vm.stopPrank();

    uint256 feeShares = vault.balanceOf(address(lendingFeeRecipient));
    assertTrue(feeShares > 0, "fee shares not minted to fee recipient");

    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.startPrank(BOT);
    lendingFeeRecipient.claimVaultFee(vaults);
    vm.stopPrank();

    assertTrue(loanToken.balanceOf(VAULT_FEE_RECEIVER) > 0, "vault fee not claimed");
  }

  function newMoolah(address admin, address manager, address pauser) internal returns (IMoolah) {
    Moolah moolahImpl = new Moolah();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, 0)
    );

    return IMoolah(address(moolahProxy));
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

  function newLendingFeeRecipient(
    address _moolah,
    address admin,
    address manager,
    address bot,
    address marketFeeRecipient,
    address vaultFeeRecipient
  ) internal returns (LendingFeeRecipient) {
    LendingFeeRecipient lendingFeeRecipientImpl = new LendingFeeRecipient();
    ERC1967Proxy lendingFeeRecipientProxy = new ERC1967Proxy(
      address(lendingFeeRecipientImpl),
      abi.encodeWithSelector(
        lendingFeeRecipientImpl.initialize.selector,
        _moolah,
        admin,
        manager,
        bot,
        marketFeeRecipient,
        vaultFeeRecipient
      )
    );

    return LendingFeeRecipient(address(lendingFeeRecipientProxy));
  }

}


// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { Test } from "forge-std/Test.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";
import { Moolah } from "moolah/Moolah.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahVaultManager } from "moolah-vault/MoolahVaultManager.sol";

contract MoolahVaultManagerTest is Test {
  using MarketParamsLib for MarketParams;
  address admin;
  address manager;
  address pauser;
  address curator;
  address allocator;
  address bot;
  address receiver;

  MarketParams marketParams1;
  MarketParams marketParams2;
  MarketParams marketParams3;

  InterestRateModel irm;
  Moolah moolah;
  MoolahVault vault;
  MoolahVaultManager vaultManager;

  function setUp() public {
    admin = makeAddr("admin");
    manager = makeAddr("manager");
    pauser = makeAddr("pauser");
    curator = makeAddr("curator");
    allocator = makeAddr("allocator");
    bot = makeAddr("bot");
    receiver = makeAddr("receiver");

    Moolah moolahImpl = new Moolah();
    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, 0)
    );
    moolah = Moolah(address(moolahProxy));

    InterestRateModel irmImpl = new InterestRateModel(address(moolah));
    ERC1967Proxy irmProxy = new ERC1967Proxy(
      address(irmImpl),
      abi.encodeWithSelector(irmImpl.initialize.selector, admin)
    );
    irm = InterestRateModel(address(irmProxy));

    ERC20Mock loanToken = new ERC20Mock();

    ERC20Mock collateralToken1 = new ERC20Mock();
    ERC20Mock collateralToken2 = new ERC20Mock();
    ERC20Mock collateralToken3 = new ERC20Mock();

    OracleMock oracle = new OracleMock();
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken1), 1e8);
    oracle.setPrice(address(collateralToken2), 1e8);
    oracle.setPrice(address(collateralToken3), 1e8);

    uint256 lltv = 0.8 ether; // 80%

    marketParams1 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken1),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });

    marketParams2 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken2),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });

    marketParams3 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken3),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });

    vm.startPrank(manager);
    moolah.enableIrm(address(irm));
    moolah.enableLltv(lltv);
    vm.stopPrank();

    moolah.createMarket(marketParams1);
    moolah.createMarket(marketParams2);
    moolah.createMarket(marketParams3);

    vault = newVault(address(loanToken));

    vm.startPrank(admin);
    vault.grantRole(vault.CURATOR(), curator);
    vm.stopPrank();
    vm.startPrank(manager);
    vault.grantRole(vault.ALLOCATOR(), allocator);
    vm.stopPrank();

    MoolahVaultManager vaultManagerImpl = new MoolahVaultManager(address(moolah));
    ERC1967Proxy vaultManagerProxy = new ERC1967Proxy(
      address(vaultManagerImpl),
      abi.encodeWithSelector(vaultManagerImpl.initialize.selector, admin, manager, bot, receiver, 0)
    );
    vaultManager = MoolahVaultManager(address(vaultManagerProxy));

    vm.startPrank(admin);
    vault.grantRole(vault.CURATOR(), address(vaultManager));
    vm.stopPrank();
    vm.startPrank(manager);
    vault.grantRole(vault.ALLOCATOR(), address(vaultManager));
    vm.stopPrank();
    vm.startPrank(manager);
    vaultManager.setMaxSupplyValue(99 ether);
    vm.stopPrank();

    vm.startPrank(manager);
    vaultManager.setMaxSupplyValue(type(uint256).max);
    vm.stopPrank();
  }

  function test_setMarket() public {
    vm.startPrank(curator);
    vault.setCap(marketParams1, 100 ether);
    vault.setCap(marketParams2, 200 ether);
    vault.setCap(marketParams3, 300 ether);
    vm.stopPrank();

    Id[] memory supplyQueue = new Id[](3);
    supplyQueue[0] = marketParams1.id();
    supplyQueue[1] = marketParams2.id();
    supplyQueue[2] = marketParams3.id();

    vm.startPrank(allocator);
    vault.setSupplyQueue(supplyQueue);
    vm.stopPrank();

    assertEq(vault.supplyQueueLength(), 3, "supply queue length should be 3");
  }

  function test_setReceiver() public {
    address newReceiver = makeAddr("newReceiver");
    vm.startPrank(manager);
    vaultManager.setReceiver(newReceiver);
    vm.stopPrank();

    assertEq(vaultManager.receiver(), newReceiver, "receiver should be updated");
  }

  function test_withdrawToken() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    loanToken.setBalance(address(vaultManager), 100 ether);

    vm.startPrank(bot);
    vaultManager.withdrawToken(address(loanToken));
    vm.stopPrank();

    assertEq(loanToken.balanceOf(receiver), 100 ether, "receiver should receive the withdrawn tokens");
  }

  function test_batchSetVaultWhitelist() public {
    MoolahVault vault1 = newVault(marketParams1.loanToken);
    MoolahVault vault2 = newVault(marketParams1.loanToken);
    MoolahVault vault3 = newVault(marketParams1.loanToken);

    address[] memory vaults = new address[](3);
    vaults[0] = address(vault1);
    vaults[1] = address(vault2);
    vaults[2] = address(vault3);

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    assertTrue(vaultManager.vaultWhitelist(address(vault1)), "vault1 should be whitelisted");
    assertTrue(vaultManager.vaultWhitelist(address(vault2)), "vault2 should be whitelisted");
    assertTrue(vaultManager.vaultWhitelist(address(vault3)), "vault3 should be whitelisted");

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, false);
    vm.stopPrank();

    assertFalse(vaultManager.vaultWhitelist(address(vault1)), "vault1 should not be whitelisted");
    assertFalse(vaultManager.vaultWhitelist(address(vault2)), "vault2 should not be whitelisted");
    assertFalse(vaultManager.vaultWhitelist(address(vault3)), "vault3 should not be whitelisted");
  }

  function newVault(address loanToken) private returns (MoolahVault) {
    MoolahVault vaultImpl = new MoolahVault(address(moolah), loanToken);
    ERC1967Proxy vaultProxy = new ERC1967Proxy(
      address(vaultImpl),
      abi.encodeWithSelector(vaultImpl.initialize.selector, admin, manager, loanToken, "test name", "test symbol")
    );
    return MoolahVault(address(vaultProxy));
  }

  function test_withdrawFromMoolah() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    loanToken.setBalance(address(this), 100 ether);

    // supply to moolah
    loanToken.approve(address(moolah), 100 ether);
    moolah.supply(marketParams1, 100 ether, 0, address(vaultManager), "");

    // withdraw from moolah to vault manager
    vm.startPrank(bot);
    vaultManager.withdrawFromMoolah(marketParams1.id());
    vm.stopPrank();

    // check the withdrawn loan token balance in vault manager
    assertEq(
      loanToken.balanceOf(address(vaultManager)),
      100 ether,
      "vault manager should receive the withdrawn loan tokens"
    );
  }

  function test_removeMarketFromVault() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    loanToken.setBalance(address(this), 1000 ether);
    loanToken.setBalance(address(vaultManager), 1000 ether);

    test_setMarket();
    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    loanToken.approve(address(vault), type(uint256).max);
    vault.deposit(600 ether, address(this));
    assertEq(vault.totalAssets(), 600 ether, "vault should have 600 assets");

    vm.startPrank(bot);
    vm.expectRevert(bytes("No market has enough cap"));
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    vault.withdraw(600 ether, address(this), address(this));
    vault.deposit(100 ether, address(this));

    vm.startPrank(bot);
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    assertEq(vault.supplyQueueLength(), 2, "supply queue length should be 2 after removing a market");
    assertEq(vault.withdrawQueueLength(), 2, "withdraw queue length should be 2 after removing a market");
    (uint184 cap, bool enabled, ) = vault.config(marketParams1.id());
    assertTrue(cap == 0 && !enabled, "market should be disabled with 0 cap");
  }

  function test_revertRemoveMarketFromVaultExceedMaxSupplyValue() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    loanToken.setBalance(address(this), 1000 ether);
    loanToken.setBalance(address(vaultManager), 1000 ether);

    test_setMarket();
    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    loanToken.approve(address(vault), type(uint256).max);
    vault.deposit(100 ether, address(this));
    assertEq(vault.totalAssets(), 100 ether, "vault should have 600 assets");

    vm.startPrank(manager);
    vaultManager.setMaxSupplyValue(99 * 1e8);
    vm.stopPrank();

    vm.startPrank(bot);
    vm.expectRevert(bytes("Exceed max supply value"));
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    vm.startPrank(manager);
    vaultManager.setMaxSupplyValue(100 * 1e8);
    vm.stopPrank();

    vm.startPrank(bot);
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();
    assertEq(vault.supplyQueueLength(), 2, "supply queue length should be 2 after removing a market");
    assertEq(vault.withdrawQueueLength(), 2, "withdraw queue length should be 2 after removing a market");
    (uint184 cap, bool enabled, ) = vault.config(marketParams1.id());
    assertTrue(cap == 0 && !enabled, "market should be disabled with 0 cap");
  }

  function test_revertWithdrawFromMoolahNotBot() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.BOT()
      )
    );
    vaultManager.withdrawFromMoolah(marketParams1.id());
  }

  function test_revertRemoveMarketFromVaultNotBot() public {
    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.BOT()
      )
    );
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
  }

  function test_revertBatchSetVaultWhitelistNotManager() public {
    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.MANAGER()
      )
    );
    vaultManager.batchSetVaultWhitelist(vaults, true);
  }

  function test_revertSetReceiverNotManager() public {
    address newReceiver = makeAddr("newReceiver");
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.MANAGER()
      )
    );
    vaultManager.setReceiver(newReceiver);
  }

  function test_revertSetMaxSupplyValueNotManager() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.MANAGER()
      )
    );
    vaultManager.setMaxSupplyValue(100 ether);
  }

  function test_revertWithdrawTokenNotBot() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    loanToken.setBalance(address(vaultManager), 100 ether);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(this),
        vaultManager.BOT()
      )
    );
    vaultManager.withdrawToken(address(loanToken));
  }
}

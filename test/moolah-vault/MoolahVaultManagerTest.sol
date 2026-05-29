// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
    vaultManager.withdrawFromMoolah(marketParams1.id(), 100 ether, 0);
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
    ERC20Mock collateralToken = ERC20Mock(marketParams1.collateralToken);
    collateralToken.setBalance(address(this), 1000 ether);

    test_setMarket();
    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);

    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    loanToken.approve(address(vault), type(uint256).max);
    vault.deposit(100 ether, address(this));
    assertEq(vault.totalAssets(), 100 ether, "vault should have 600 assets");

    collateralToken.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(marketParams1, 1000 ether, address(this), "");
    moolah.borrow(marketParams1, 100 ether, 0, address(this), address(this));

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
    vaultManager.withdrawFromMoolah(marketParams1.id(), 0, 0);
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

  // Bug 1 fix: market is in withdrawQueue but not in supplyQueue.
  // Before the fix, sizing newSupplyQueue as supplyQueueLength - 1 caused an out-of-bounds panic.
  // After the fix, the loop records supplyIdx as a sentinel; setSupplyQueue is skipped when the
  // target market is absent. Only the withdraw queue must contain the target.
  function test_removeMarketNotInSupplyQueue_skipsSupplyQueueRebuild() public {
    // Enable all three markets (so they all sit in withdrawQueue).
    vm.startPrank(curator);
    vault.setCap(marketParams1, 100 ether);
    vault.setCap(marketParams2, 200 ether);
    vault.setCap(marketParams3, 300 ether);
    vm.stopPrank();

    // supplyQueue intentionally omits marketParams1.
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = marketParams2.id();
    supplyQueue[1] = marketParams3.id();
    vm.startPrank(allocator);
    vault.setSupplyQueue(supplyQueue);
    vm.stopPrank();

    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);
    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    assertEq(vault.withdrawQueueLength(), 3, "withdraw queue length should start at 3");
    assertEq(vault.supplyQueueLength(), 2, "supply queue length should start at 2");

    vm.startPrank(bot);
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    // market1 removed from withdrawQueue; supplyQueue untouched (it never held market1).
    assertEq(vault.withdrawQueueLength(), 2, "withdraw queue length should be 2");
    assertEq(vault.supplyQueueLength(), 2, "supply queue length should remain 2");
    (uint184 cap, bool enabled, ) = vault.config(marketParams1.id());
    assertTrue(cap == 0 && !enabled, "market1 should be disabled with cap 0");
    // The other two supply queue entries are still market2 and market3.
    assertEq(Id.unwrap(vault.supplyQueue(0)), Id.unwrap(marketParams2.id()), "supplyQueue[0] = market2");
    assertEq(Id.unwrap(vault.supplyQueue(1)), Id.unwrap(marketParams3.id()), "supplyQueue[1] = market3");
  }

  // Bug 2 fix: vault has supplyShares > 0 but expectedSupplyAssets rounds to 0
  // (e.g. after bad-debt socialization wipes totalSupplyAssets).
  // Before the fix, reallocate was skipped (vaultSupplyAssets == 0) and updateWithdrawQueue
  // reverted with InvalidMarketRemovalNonZeroSupply. After the fix, setMarketRemoval is invoked
  // when residual shares remain, letting updateWithdrawQueue clean up in the same tx.
  function test_removeMarketSharesPositiveAssetsZero_setsMarketRemoval() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    ERC20Mock collateralToken = ERC20Mock(marketParams1.collateralToken);
    OracleMock oracleMock = OracleMock(marketParams1.oracle);

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

    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);
    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    // Vault deposits 1 wei → market1 TSA=1, TSS=1e6, vault.shares=1e6.
    loanToken.setBalance(address(this), 1);
    loanToken.approve(address(vault), 1);
    vault.deposit(1, address(this));

    address borrower = makeAddr("borrower");
    collateralToken.setBalance(borrower, 100 ether);
    vm.startPrank(borrower);
    collateralToken.approve(address(moolah), 100 ether);
    moolah.supplyCollateral(marketParams1, 100 ether, borrower, "");
    moolah.borrow(marketParams1, 1, 0, borrower, borrower);
    vm.stopPrank();

    // Drop collateral price to 0; liquidate full collateral to trigger bad-debt path that wipes TSA.
    oracleMock.setPrice(address(collateralToken), 0);
    address liquidator = makeAddr("liquidator");
    vm.startPrank(liquidator);
    moolah.liquidate(marketParams1, borrower, 100 ether, 0, "");
    vm.stopPrank();

    // Sanity: shares > 0 but expectedSupplyAssets == 0.
    (uint256 vss, , ) = moolah.position(marketParams1.id(), address(vault));
    assertGt(vss, 0, "vault should still hold supplyShares");
    (uint128 tsa, , , , , ) = moolah.market(marketParams1.id());
    assertEq(tsa, 0, "market TSA should be 0 after bad debt");

    vm.startPrank(bot);
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    // market1 successfully dropped from both queues; vault's stale Moolah shares are intentionally
    // left behind (their assets value is 0, so nothing is lost).
    assertEq(vault.withdrawQueueLength(), 2, "withdraw queue length should be 2");
    assertEq(vault.supplyQueueLength(), 2, "supply queue length should be 2");
    (uint184 cap, bool enabled, ) = vault.config(marketParams1.id());
    assertTrue(cap == 0 && !enabled, "market1 should be disabled with cap 0");
  }

  // Bug 3 fix: when the vault-side deficit (supplyAssets) is smaller than the market's minLoan,
  // calling MOOLAH.supply(supplyAssets + 1) reverts with "remain supply too low" because the
  // resulting vaultManager position falls under minLoan. Fix: top up with at least minLoan.
  function test_removeMarketTopUpBelowMinLoan() public {
    ERC20Mock loanToken = ERC20Mock(marketParams1.loanToken);
    ERC20Mock collateralToken = ERC20Mock(marketParams1.collateralToken);

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

    address[] memory vaults = new address[](1);
    vaults[0] = address(vault);
    vm.startPrank(manager);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopPrank();

    // Fund vaultManager so it can top up.
    loanToken.setBalance(address(vaultManager), 100 ether);

    // Vault deposits 100 ether → vault sole supplier of market1.
    loanToken.setBalance(address(this), 100 ether);
    loanToken.approve(address(vault), 100 ether);
    vault.deposit(100 ether, address(this));

    // Borrow 0.5 ether against 100 ether of collateral while minLoanValue == 0.
    address borrower = makeAddr("borrower");
    collateralToken.setBalance(borrower, 100 ether);
    vm.startPrank(borrower);
    collateralToken.approve(address(moolah), 100 ether);
    moolah.supplyCollateral(marketParams1, 100 ether, borrower, "");
    moolah.borrow(marketParams1, 0.5 ether, 0, borrower, borrower);
    vm.stopPrank();

    // Raise minLoanValue so minLoan(market1) = 1 ether (price 1e8, 18 decimals → 1e8 * 1e18 / 1e8).
    // Now the vault-side deficit (~0.5 ether) is below minLoan, exercising Bug 3.
    vm.prank(manager);
    moolah.setMinLoanValue(1e8);
    assertEq(moolah.minLoan(marketParams1), 1 ether, "minLoan should be 1 ether");

    vm.startPrank(bot);
    vaultManager.removeMarketFromVault(address(vault), marketParams1.id());
    vm.stopPrank();

    assertEq(vault.withdrawQueueLength(), 2, "withdraw queue length should be 2");
    assertEq(vault.supplyQueueLength(), 2, "supply queue length should be 2");
    (uint184 cap, bool enabled, ) = vault.config(marketParams1.id());
    assertTrue(cap == 0 && !enabled, "market1 should be disabled with cap 0");
  }
}

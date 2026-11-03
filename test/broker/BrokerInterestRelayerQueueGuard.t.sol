// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMockZero } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";
import { IBrokerInterestRelayer } from "../../src/broker/interfaces/IBrokerInterestRelayer.sol";
import { RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketAllocation } from "../../src/moolah-vault/interfaces/IMoolahVault.sol";
import { BrokerInterestLockBuffer } from "../../src/utils/BrokerInterestLockBuffer.sol";

/// @dev Relayer must not supply broker revenue into a market the vault no longer tracks (removed from
///      withdrawQueue): the assets would be invisible to totalAssets() while the lock buffer still deducts them.
///      Two brokers share one relayer / vault here; market 1 gets removed from the vault, market 2 stays.
contract BrokerInterestRelayerQueueGuardTest is Test {
  using MarketParamsLib for MarketParams;
  using MoolahBalancesLib for IMoolah;

  IMoolah public moolah;
  MoolahVault public vault;
  BrokerInterestRelayer public relayer;
  BrokerInterestLockBuffer public lockBuffer;
  RateCalculator public rateCalc;
  LendingBroker public broker1;
  LendingBroker public broker2;

  ERC20Mock public LISUSD;
  ERC20Mock public BTCB;
  ERC20Mock public ETHB;
  OracleMock public oracle;
  IrmMockZero public irm;
  MarketParams public mp1;
  MarketParams public mp2;
  Id public id1;
  Id public id2;

  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MANAGER = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;
  address constant PAUSER = address(0xA11A51);
  address constant BOT = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  uint64 constant LOCK_DURATION = 8 hours;
  uint256 constant RELAY = 100 ether; // Moolah minLoan in this fixture is $15

  function setUp() public {
    Moolah mImpl = new Moolah();
    ERC1967Proxy mProxy = new ERC1967Proxy(
      address(mImpl),
      abi.encodeWithSelector(Moolah.initialize.selector, ADMIN, MANAGER, PAUSER, 15e8)
    );
    moolah = IMoolah(address(mProxy));

    LISUSD = new ERC20Mock();
    LISUSD.setDecimals(18);
    BTCB = new ERC20Mock();
    BTCB.setDecimals(18);
    ETHB = new ERC20Mock();
    ETHB.setDecimals(18);

    oracle = new OracleMock();
    oracle.setPrice(address(LISUSD), 1e8);
    oracle.setPrice(address(BTCB), 120000e8);
    oracle.setPrice(address(ETHB), 4000e8);

    irm = new IrmMockZero();
    vm.startPrank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    Moolah(address(moolah)).enableLltv(80 * 1e16);
    vm.stopPrank();

    MoolahVault vaultImpl = new MoolahVault(address(moolah), address(LISUSD));
    ERC1967Proxy vaultProxy = new ERC1967Proxy(
      address(vaultImpl),
      abi.encodeWithSelector(MoolahVault.initialize.selector, ADMIN, MANAGER, address(LISUSD), "V", "V")
    );
    vault = MoolahVault(address(vaultProxy));

    BrokerInterestRelayer relayerImpl = new BrokerInterestRelayer();
    ERC1967Proxy relayerProxy = new ERC1967Proxy(
      address(relayerImpl),
      abi.encodeWithSelector(
        BrokerInterestRelayer.initialize.selector,
        ADMIN,
        MANAGER,
        address(moolah),
        address(vault),
        address(LISUSD)
      )
    );
    relayer = BrokerInterestRelayer(address(relayerProxy));

    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    rateCalc = RateCalculator(address(rcProxy));

    broker1 = _newBroker();
    broker2 = _newBroker();

    mp1 = MarketParams(address(LISUSD), address(BTCB), address(broker1), address(irm), 80 * 1e16);
    mp2 = MarketParams(address(LISUSD), address(ETHB), address(broker2), address(irm), 80 * 1e16);
    id1 = mp1.id();
    id2 = mp2.id();
    Moolah(address(moolah)).createMarket(mp1);
    Moolah(address(moolah)).createMarket(mp2);

    vm.startPrank(MANAGER);
    broker1.setMarketId(id1);
    broker2.setMarketId(id2);
    rateCalc.registerBroker(address(broker1), RATE_SCALE + 1, RATE_SCALE + 2);
    rateCalc.registerBroker(address(broker2), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(id1, address(broker1), true);
    Moolah(address(moolah)).setMarketBroker(id2, address(broker2), true);
    relayer.addBroker(address(broker1));
    relayer.addBroker(address(broker2));
    vm.stopPrank();

    // vault tracks both markets
    bytes32 curator = vault.CURATOR();
    bytes32 allocator = vault.ALLOCATOR();
    vm.prank(ADMIN);
    vault.grantRole(curator, MANAGER);
    vm.startPrank(MANAGER);
    vault.grantRole(allocator, MANAGER);
    vault.setCap(mp1, type(uint184).max);
    vault.setCap(mp2, type(uint184).max);
    Id[] memory sq = new Id[](2);
    sq[0] = id1;
    sq[1] = id2;
    vault.setSupplyQueue(sq);
    vm.stopPrank();

    // lock buffer wired to the vault, relayer allowed to notify
    BrokerInterestLockBuffer bufImpl = new BrokerInterestLockBuffer();
    ERC1967Proxy bufProxy = new ERC1967Proxy(
      address(bufImpl),
      abi.encodeWithSelector(
        BrokerInterestLockBuffer.initialize.selector,
        ADMIN,
        MANAGER,
        address(vault),
        address(LISUSD),
        LOCK_DURATION
      )
    );
    lockBuffer = BrokerInterestLockBuffer(address(bufProxy));
    bytes32 bufRelayer = lockBuffer.RELAYER();
    vm.prank(ADMIN);
    lockBuffer.grantRole(bufRelayer, address(relayer));
    vm.prank(MANAGER);
    vault.setLockBuffer(address(lockBuffer));

    // seed the vault with a real position so NAV is non-trivial
    LISUSD.setBalance(address(this), 10_000 ether);
    LISUSD.approve(address(vault), type(uint256).max);
    vault.deposit(10_000 ether, address(this));
  }

  // ===== helpers =====

  function _newBroker() internal returns (LendingBroker b) {
    LendingBroker impl = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    b = LendingBroker(payable(address(proxy)));
  }

  /// @dev what a broker does on repay / liquidate: hand interest to the relayer
  function _relay(LendingBroker b, uint256 amount) internal {
    LISUSD.setBalance(address(b), LISUSD.balanceOf(address(b)) + amount);
    vm.startPrank(address(b));
    IERC20(address(LISUSD)).approve(address(relayer), amount);
    relayer.supplyToVault(amount);
    vm.stopPrank();
  }

  function _vaultAssetsIn(Id id, MarketParams memory mp) internal view returns (uint256) {
    return moolah.expectedSupplyAssets(mp, address(vault));
  }

  // ===== tests =====

  function test_enabledMarket_relayUnchanged() public {
    uint256 navBefore = vault.totalAssets();
    uint256 posBefore = _vaultAssetsIn(id2, mp2);

    _relay(broker2, RELAY);

    assertEq(LISUSD.balanceOf(address(relayer)), 0, "balance flushed");
    assertApproxEqAbs(_vaultAssetsIn(id2, mp2) - posBefore, RELAY, 1, "supplied into market 2");
    assertEq(lockBuffer.currentLocked(), RELAY, "full amount locked");
    assertApproxEqAbs(vault.totalAssets(), navBefore, 1, "NAV flat at flush time (locked)");
  }

  function test_removedMarket_relayIsKeptInRelayer() public {
    _removeMarketWithReallocate();
    uint256 navBefore = vault.totalAssets();
    uint256 posBefore = _vaultAssetsIn(id1, mp1);

    LISUSD.setBalance(address(broker1), RELAY);
    vm.startPrank(address(broker1));
    IERC20(address(LISUSD)).approve(address(relayer), RELAY);
    vm.expectEmit(true, true, false, true);
    emit IBrokerInterestRelayer.SupplySkippedMarketNotEnabled(address(broker1), id1, RELAY);
    relayer.supplyToVault(RELAY);
    vm.stopPrank();

    assertEq(LISUSD.balanceOf(address(relayer)), RELAY, "balance kept in relayer");
    assertEq(_vaultAssetsIn(id1, mp1), posBefore, "nothing supplied into the untracked market");
    assertEq(lockBuffer.currentLocked(), 0, "lock buffer not notified");
    assertEq(vault.totalAssets(), navBefore, "NAV untouched");
  }

  function test_removedMarket_balanceCarriedOverByEnabledBroker() public {
    _removeMarketWithReallocate();
    _relay(broker1, RELAY); // kept
    uint256 posBefore = _vaultAssetsIn(id2, mp2);

    _relay(broker2, RELAY / 2);

    assertEq(LISUSD.balanceOf(address(relayer)), 0, "whole balance flushed");
    assertApproxEqAbs(_vaultAssetsIn(id2, mp2) - posBefore, RELAY + RELAY / 2, 1, "both relays land in market 2");
    assertEq(lockBuffer.currentLocked(), RELAY + RELAY / 2, "lock covers the carried-over amount too");
  }

  // ===== market removal helper (cap 0 → reallocate out → drop from withdrawQueue) =====

  function _removeMarketWithReallocate() internal {
    vm.startPrank(MANAGER);
    vault.setCap(mp1, 0);
    // pull all vault liquidity out of market 1 into market 2
    MarketAllocation[] memory allocs = new MarketAllocation[](2);
    allocs[0] = MarketAllocation({ marketParams: mp1, assets: 0 });
    allocs[1] = MarketAllocation({ marketParams: mp2, assets: type(uint256).max });
    vault.reallocate(allocs);
    uint256[] memory keep = new uint256[](1);
    keep[0] = 1; // withdrawQueue is [id1, id2]; keep id2
    vault.updateWithdrawQueue(keep);
    Id[] memory sq = new Id[](1);
    sq[0] = id2;
    vault.setSupplyQueue(sq);
    vm.stopPrank();
    assertFalse(_enabled(id1), "market 1 no longer tracked");
    assertTrue(_enabled(id2), "market 2 still tracked");
  }

  function _enabled(Id id) internal view returns (bool enabled) {
    (, enabled, ) = vault.config(id);
  }
}

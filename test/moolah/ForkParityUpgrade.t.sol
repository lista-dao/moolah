// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";

import { MarketFactory } from "moolah/MarketFactory.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { Liquidator } from "liquidator/Liquidator.sol";

/**
 * @title ForkParityUpgrade
 * @notice Mainnet-fork simulation of the runbook upgrades, proving markets can still be created afterwards.
 *  TEST 1 (BSC): MarketFactory immutable->storage break + Mechanism-B re-init (setRateCalculator/setBrokerLiquidator).
 *  TEST 2 (ETH): Liquidator UUPS upgrade adds reflowBlacklist, unblocking the smart-collateral market-creation path.
 *
 *  Run: forge test --match-contract ForkParityUpgrade -vvv
 */
contract ForkParityUpgrade is Test {
  using MarketParamsLib for MarketParams;

  // ─── BSC addresses ───
  address constant BSC_FACTORY = 0xce26859127d236a61f168d2d0905f77d7E286Ab2;
  address constant BSC_TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant BSC_RATE_CALCULATOR = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;
  address constant BSC_BROKER_LIQUIDATOR = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;
  address constant BSC_IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c; // enabled AdaptiveCurveIrm
  address constant BSC_LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // whitelisted loan token everywhere
  uint256 constant BSC_LLTV = 0.8 ether; // enabled

  // ─── ETH addresses ───
  address constant ETH_LIQUIDATOR = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
  address constant ETH_TIMELOCK = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;

  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MANAGER = keccak256("MANAGER");

  // ============================================================================
  // TEST 1 — BSC MarketFactory upgrade + rc/bl re-init
  // ============================================================================
  function test_BSC_MarketFactory_upgrade_and_reinit() public {
    vm.createSelectFork(vm.rpcUrl("bsc"));

    MarketFactory factory = MarketFactory(BSC_FACTORY);

    // Read the 10 constructor immutables from the live proxy getters.
    address _moolah = address(factory.moolah());
    address _liquidator = address(factory.liquidator());
    address _publicLiquidator = address(factory.publicLiquidator());
    address _revenueDistributor = address(factory.revenueDistributor());
    address _buyBack = address(factory.buyBack());
    address _autoBuyBack = address(factory.autoBuyBack());
    address _WBNB = factory.WBNB();
    address _sliBNB = factory.sliBNB();
    address _BNBProvider = factory.BNBProvider();
    address _slisBNBProvider = factory.slisBNBProvider();

    emit log_named_address("live moolah", _moolah);
    emit log_named_address("live rateCalculator (immutable, pre-upgrade)", address(factory.rateCalculator()));
    emit log_named_address("live brokerLiquidator (immutable, pre-upgrade)", address(factory.brokerLiquidator()));

    // (a) Deploy new impl (rc/bl are now STORAGE, not immutable).
    MarketFactory newImpl = new MarketFactory(
      _moolah,
      _liquidator,
      _publicLiquidator,
      _revenueDistributor,
      _buyBack,
      _autoBuyBack,
      _WBNB,
      _sliBNB,
      _BNBProvider,
      _slisBNBProvider
    );

    // (b) NEGATIVE CONTROL: empty upgrade, no re-init → storage slots default to 0 (immutable values lost).
    vm.prank(BSC_TIMELOCK);
    factory.upgradeToAndCall(address(newImpl), "");
    assertEq(address(factory.rateCalculator()), address(0), "(b) rateCalculator must be 0 after empty upgrade");
    assertEq(address(factory.brokerLiquidator()), address(0), "(b) brokerLiquidator must be 0 after empty upgrade");
    emit log("(b) PASS: rc/bl lost after empty upgrade (immutable->storage break confirmed)");

    // (c) Grant OPERATOR to this test contract.
    vm.prank(BSC_TIMELOCK);
    factory.grantRole(OPERATOR, address(this));
    assertTrue(factory.hasRole(OPERATOR, address(this)), "(c) OPERATOR grant failed");

    // (d) Fixed-term path is broken without re-init: reverts "RateCalculator not set".
    MarketFactory.FixedTermMarketParams memory dummy = MarketFactory.FixedTermMarketParams({
      broker: address(0xBEEF),
      loanToken: address(0xA1),
      collateralToken: address(0xA2),
      irm: BSC_IRM,
      lltv: BSC_LLTV,
      ratePerSecond: 1,
      maxRatePerSecond: 2
    });
    vm.expectRevert(bytes("RateCalculator not set"));
    factory.createFixedTermMarket(dummy);
    emit log("(d) PASS: createFixedTermMarket reverted 'RateCalculator not set' before re-init");

    // (e) FIX (Mechanism B): re-init rc/bl.
    vm.prank(BSC_TIMELOCK);
    factory.setRateCalculator(BSC_RATE_CALCULATOR);
    vm.prank(BSC_TIMELOCK);
    factory.setBrokerLiquidator(BSC_BROKER_LIQUIDATOR);
    assertEq(address(factory.rateCalculator()), BSC_RATE_CALCULATOR, "(e) rateCalculator not restored");
    assertEq(address(factory.brokerLiquidator()), BSC_BROKER_LIQUIDATOR, "(e) brokerLiquidator not restored");
    emit log("(e) PASS: rc/bl restored via setRateCalculator/setBrokerLiquidator");

    // (f) rc/bl guard now passes: must NOT revert with "RateCalculator not set".
    bool passedGuard;
    try factory.createFixedTermMarket(dummy) returns (Id) {
      passedGuard = true; // no revert at all — guard cleared
      emit log("(f) createFixedTermMarket did not revert (guard cleared)");
    } catch Error(string memory reason) {
      passedGuard = keccak256(bytes(reason)) != keccak256(bytes("RateCalculator not set"));
      emit log_named_string("(f) revert reason (string)", reason);
    } catch (bytes memory lowlevel) {
      passedGuard = true; // reverted without the guard string → got past the guard (fake broker 0xBEEF)
      emit log_named_bytes("(f) low-level revert (no string)", lowlevel);
    }
    assertTrue(passedGuard, "(f) still blocked by 'RateCalculator not set' guard");
    emit log("(f) PASS: fixed-term path is past the RateCalculator guard after re-init");

    // (g) END-TO-END common market creation via the upgraded factory.
    IMoolah moolah = IMoolah(_moolah);
    assertTrue(moolah.isIrmEnabled(BSC_IRM), "irm should be enabled");
    assertTrue(moolah.isLltvEnabled(BSC_LLTV), "lltv should be enabled");

    // Fresh oracle + fresh collateral => unique market id; lisUSD loan token is already whitelisted downstream.
    OracleMock oracle = new OracleMock();
    ERC20Mock collateral = new ERC20Mock();
    oracle.setPrice(BSC_LISUSD, 1e18);
    oracle.setPrice(address(collateral), 1e18);

    MarketParams memory param = MarketParams({
      loanToken: BSC_LISUSD,
      collateralToken: address(collateral),
      oracle: address(oracle),
      irm: BSC_IRM,
      lltv: BSC_LLTV
    });
    Id id = param.id();

    address[] memory empty = new address[](0);
    // Called as OPERATOR (address(this)); factory internally uses its live downstream roles.
    factory.createMarket(param, empty, empty, false, false);

    assertGt(moolah.market(id).lastUpdate, 0, "(g) market should exist after createMarket");
    emit log_named_bytes32("(g) PASS: created common market id", Id.unwrap(id));
  }

  // ============================================================================
  // TEST 2 — ETH Liquidator upgrade to reflow-blacklist
  // ============================================================================
  function test_ETH_Liquidator_upgrade_unblocks_reflowBlacklist() public {
    vm.createSelectFork(vm.rpcUrl("eth"));

    Liquidator liq = Liquidator(payable(ETH_LIQUIDATOR));

    // (a) BEFORE upgrade: reflowBlacklist(address) selector is absent on the old impl.
    (bool okBefore, ) = ETH_LIQUIDATOR.staticcall(abi.encodeWithSignature("reflowBlacklist(address)", address(0x1234)));
    assertFalse(okBefore, "(a) reflowBlacklist must be ABSENT (revert) pre-upgrade");
    emit log("(a) PASS: reflowBlacklist absent on live Liquidator impl (staticcall failed)");

    // Read the MOOLAH immutable from the live proxy and deploy the new impl.
    address _moolah = liq.MOOLAH();
    Liquidator newLiqImpl = new Liquidator(_moolah);

    // (b) Upgrade.
    vm.prank(ETH_TIMELOCK);
    liq.upgradeToAndCall(address(newLiqImpl), "");
    emit log("(b) PASS: Liquidator upgraded");

    // (c) AFTER upgrade: reflowBlacklist(someAddr) returns false without reverting.
    address someAddr = address(0x1234);
    bool r = liq.reflowBlacklist(someAddr);
    assertFalse(r, "(c) reflowBlacklist should be false by default post-upgrade");
    emit log("(c) PASS: reflowBlacklist callable, returns false");

    // (d) Reproduce the ETH MarketFactory _configSmartProvider call: MANAGER.setReflowBlacklist(collateral, true).
    address someCollateral = address(0xC0111a7e4a1);
    vm.prank(ETH_TIMELOCK);
    liq.grantRole(MANAGER, address(this));
    assertTrue(liq.hasRole(MANAGER, address(this)), "(d) MANAGER grant failed");

    liq.setReflowBlacklist(someCollateral, true);
    assertTrue(liq.reflowBlacklist(someCollateral), "(d) setReflowBlacklist did not persist");
    emit log("(d) PASS: setReflowBlacklist(collateral,true) succeeded (smart-collateral path unblocked)");
  }
}

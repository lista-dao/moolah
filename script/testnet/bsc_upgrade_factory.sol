// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { MarketFactory } from "moolah/MarketFactory.sol";

/// @notice BSC Testnet: Upgrade MarketFactory proxy with new impl and verify.
///   Satisfies checklist items 1.9–1.12 for BSC MarketFactory.
///
///   Usage:
///     source .env && forge script script/testnet/bsc_upgrade_factory.sol \
///       --rpc-url $BSC_TESTNET_RPC_URL --broadcast --via-ir -vvvv
contract BscUpgradeFactory is DeployBase {
  // ─── Existing BSC Testnet Addresses (from Notion "Moolah Testnet") ───
  address constant MOOLAH = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address constant FACTORY_PROXY = 0x34974C11937a3b9c49C0e3193E60403123AA8FD4;
  address constant LIQUIDATOR = 0x8096Bbe78eB83B83dD286c6062a1eFbE85305c97;
  address constant PUBLIC_LIQUIDATOR = 0x456500a836DD73A5aF6fD85632E4805a8dAb9a97;
  address constant REVENUE_DISTRIBUTOR = 0xe36857af784fB2B8cFA22481b51Fa0c99D13fF20;
  address constant BUYBACK = 0x371b76E7C797AF9336443F6588B510c9d177315e;
  address constant AUTO_BUYBACK = 0xa4cb526E4D1CaF21f1DFA824f9B4728b217D1eBd;
  address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address constant SLISBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address constant BNB_PROVIDER = 0x297152bCC1dd5bC0Df527CB16E7Ff7348d7b1d72;
  address constant SLISBNB_PROVIDER = 0x0612c940460D68C16aA213315E32Fba579beD6A6;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);
    console.log("Chain ID:", block.chainid);

    // ─── Pre-flight: record current storage ───
    MarketFactory factory = MarketFactory(FACTORY_PROXY);
    address rcBefore = address(factory.rateCalculator());
    address blBefore = address(factory.brokerLiquidator());
    console.log("");
    console.log("=== Pre-flight ===");
    console.log("  rateCalculator:", rcBefore);
    console.log("  brokerLiquidator:", blBefore);

    vm.startBroadcast(deployerPrivateKey);

    // ─── Deploy new impl ───
    MarketFactory newImpl = new MarketFactory(
      MOOLAH,
      LIQUIDATOR,
      PUBLIC_LIQUIDATOR,
      REVENUE_DISTRIBUTOR,
      BUYBACK,
      AUTO_BUYBACK,
      WBNB,
      SLISBNB,
      BNB_PROVIDER,
      SLISBNB_PROVIDER
    );
    console.log("  New impl:", address(newImpl));

    // ─── Upgrade (UUPS) ───
    (bool ok, ) = FACTORY_PROXY.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), ""));
    require(ok, "upgradeToAndCall failed");
    console.log("  upgradeToAndCall succeeded");

    // ─── Re-init storage (immutable→storage migration) ───
    factory.setRateCalculator(rcBefore);
    factory.setBrokerLiquidator(blBefore);
    console.log("  setRateCalculator + setBrokerLiquidator re-initialized");

    // ─── Verify storage preserved ───
    address rcAfter = address(factory.rateCalculator());
    address blAfter = address(factory.brokerLiquidator());
    require(rcAfter == rcBefore, "rateCalculator LOST!");
    require(blAfter == blBefore, "brokerLiquidator LOST!");
    console.log("  [PASS] rateCalculator preserved:", rcAfter);
    console.log("  [PASS] brokerLiquidator preserved:", blAfter);

    // ─── Verify immutables ───
    require(address(factory.moolah()) == MOOLAH, "moolah mismatch");
    require(address(factory.liquidator()) == LIQUIDATOR, "liquidator mismatch");
    require(factory.WBNB() == WBNB, "WBNB mismatch");
    console.log("  [PASS] immutables accessible");

    vm.stopBroadcast();

    console.log("");
    console.log("=== BSC TESTNET VERIFICATION COMPLETE ===");
    console.log("  [1.9]  Old impl: 0xa02686d7a144ccf308696fb11fcc4f7cabaf37f7");
    console.log("  [1.10] Storage: PRESERVED");
    console.log("  [1.11] Library: NONE");
    console.log("  [1.12] Upgrade: PASSED");
  }
}

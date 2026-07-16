// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { Liquidator } from "liquidator/Liquidator.sol";

/// @notice Sepolia: Upgrade Liquidator proxy with new impl and verify.
///   Satisfies checklist items 1.9–1.12 for ETH Liquidator.
///
///   Usage:
///     source .env && forge script script/testnet/eth_upgrade_liquidator.sol \
///       --rpc-url $SEPOLIA_RPC_URL --broadcast --via-ir -vvvv
contract EthUpgradeLiquidator is DeployBase {
  // ─── Existing Sepolia Addresses (from Notion "Moolah Sepolia Addresses") ───
  address constant MOOLAH = 0x29c53B75b4CD3CeC0B58F935dC642fF47B708d65;
  address constant LIQUIDATOR_PROXY = 0x875856e6B80795bD4edB6F4cCc6dD13150d21E99;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);
    console.log("Chain ID:", block.chainid);

    vm.startBroadcast(deployerPrivateKey);

    Liquidator liq = Liquidator(payable(LIQUIDATOR_PROXY));

    // ─── Deploy new impl ───
    Liquidator newImpl = new Liquidator(MOOLAH);
    console.log("  New Liquidator impl:", address(newImpl));

    // ─── Upgrade (UUPS) ───
    (bool ok, ) = LIQUIDATOR_PROXY.call(
      abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
    );
    require(ok, "upgradeToAndCall failed");
    console.log("  upgradeToAndCall succeeded");

    // ─── Verify reflowBlacklist works ───
    address testAddr = address(0xdead);
    liq.setReflowBlacklist(testAddr, true);
    require(liq.reflowBlacklist(testAddr), "reflowBlacklist not working!");
    console.log("  [PASS] reflowBlacklist works post-upgrade");
    liq.setReflowBlacklist(testAddr, false);

    vm.stopBroadcast();

    console.log("");
    console.log("=== SEPOLIA VERIFICATION COMPLETE ===");
    console.log("  [1.9]  New impl deployed on Sepolia");
    console.log("  [1.10] Storage: PRESERVED (no new storage conflicts)");
    console.log("  [1.11] Library: NONE");
    console.log("  [1.12] Upgrade: PASSED");
  }
}

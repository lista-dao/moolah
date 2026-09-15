// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { PositionMigrator } from "../../src/utils/PositionMigrator.sol";
import { IYieldAccount } from "../../src/utils/interfaces/IYieldAccount.sol";
import { Id } from "moolah/interfaces/IMoolah.sol";

/// @dev Deploys the PositionMigrator implementation carrying the routed-account branch, and prints
///      the two TimeLock actions that follow: the proxy upgrade, then setYieldAccount.
/// @dev Routing stays off until setYieldAccount runs — the account address is storage, not bytecode.
contract UpgradePositionMigratorYieldAccount is DeployBase {
  address migratorProxy = 0x2B3E5b695722756130A553E9Bb5A45E16d21D0A4;

  function run() public {
    /// @dev the YieldAccount proxy from script/utils/deploy_yieldAccount.s.sol
    address yieldAccount = vm.envAddress("YIELD_ACCOUNT");
    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer: ", vm.addr(deployerPrivateKey));
    console.log("YieldAccount: ", yieldAccount);
    require(yieldAccount != address(0), "YIELD_ACCOUNT not set");

    bytes32 marketId = Id.unwrap(IYieldAccount(yieldAccount).marketId());
    console.log("YieldAccount market id:");
    console.logBytes32(marketId);

    vm.startBroadcast(deployerPrivateKey);
    PositionMigrator impl = new PositionMigrator();
    console.log("PositionMigrator implementation: ", address(impl));
    vm.stopBroadcast();

    require(impl.YIELD_ACCOUNT_OWNER() == 0x0966602E47F6a3CA5692529F1D54EcD1d9B09175, "account owner");

    console.log("TimeLock action 1: upgradeToAndCall on proxy");
    console.log("  proxy: ", migratorProxy);
    console.log("  impl:  ", address(impl));
    console.log("TimeLock action 2: setYieldAccount(account, marketId) on proxy");
    console.log("  account: ", yieldAccount);
  }
}

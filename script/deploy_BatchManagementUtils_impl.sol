// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { BatchManagementUtils } from "src/utils/BatchManagementUtils.sol";

/// @notice Deploys the BatchManagementUtils implementation only on BSC mainnet (no proxy).
///         Use this when upgrading the existing mainnet proxy via UUPS upgradeToAndCall.
contract BatchManagementUtilsImplDeploy is DeployBase {
  function run() public {
    address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C; // BSC mainnet Moolah
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);
    BatchManagementUtils impl = new BatchManagementUtils(moolah);
    console.log("new implementation: ", address(impl));
    vm.stopBroadcast();
  }
}

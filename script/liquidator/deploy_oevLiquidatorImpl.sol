// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { OEVLiquidator } from "liquidator/OEVLiquidator.sol";

/// @dev Deploys a new OEVLiquidator implementation only. Upgrade the proxy via TimeLock afterwards.
contract OEVLiquidatorImplDeploy is DeployBase {
  address moolah;

  function setUp() public {
    moolah = vm.envAddress("MOOLAH");
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy OEVLiquidator implementation
    OEVLiquidator impl = new OEVLiquidator(moolah);
    console.log("OEVLiquidator implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

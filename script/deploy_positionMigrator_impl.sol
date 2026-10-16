pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { PositionMigrator } from "../src/utils/PositionMigrator.sol";

contract PositionMigratorImplDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PositionMigrator implementation
    PositionMigrator impl = new PositionMigrator();
    console.log("PositionMigrator implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

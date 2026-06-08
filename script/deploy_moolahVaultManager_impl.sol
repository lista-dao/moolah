pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { MoolahVaultManager } from "moolah-vault/MoolahVaultManager.sol";

contract MoolahVaultManagerImplDeploy is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVaultManager implementation
    MoolahVaultManager impl = new MoolahVaultManager(moolah);
    console.log("MoolahVaultManager implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

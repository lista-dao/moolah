pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { MoolahVaultManager } from "moolah-vault/MoolahVaultManager.sol";

contract MoolahVaultManagerTransferRoleDeploy is DeployBase {
  MoolahVaultManager vaultManager = MoolahVaultManager(0x0000000000000000000000000000000000000000);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // miltisig

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    vaultManager.grantRole(DEFAULT_ADMIN_ROLE, admin);
    vaultManager.grantRole(MANAGER, manager);

    vaultManager.revokeRole(MANAGER, deployer);
    vaultManager.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

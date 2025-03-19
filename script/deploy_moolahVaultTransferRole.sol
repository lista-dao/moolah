pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  // todo
  MoolahVault vault = MoolahVault(0xA5edCb7c60448f7779361afc2F92f858f3A6dd1E);
  address admin = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54; // timelock
  address manager = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54; // timelock
  address allocator = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address curator = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    vault.grantRole(MANAGER, manager);
    vault.grantRole(ALLOCATOR, allocator);
    vault.grantRole(CURATOR, curator);

    vault.revokeRole(CURATOR, deployer);
    vault.revokeRole(ALLOCATOR, deployer);
    vault.revokeRole(MANAGER, deployer);
    vault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

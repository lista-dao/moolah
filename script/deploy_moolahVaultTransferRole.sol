pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  MoolahVault vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85; // timelock
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address curator = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;

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

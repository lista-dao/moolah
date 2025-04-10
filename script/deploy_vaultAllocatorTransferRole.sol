pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  VaultAllocator vaultAllocator = VaultAllocator(0x9ECF66f016FCaA853FdA24d223bdb4276E5b524a);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock

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
    vaultAllocator.grantRole(DEFAULT_ADMIN_ROLE, admin);
    vaultAllocator.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

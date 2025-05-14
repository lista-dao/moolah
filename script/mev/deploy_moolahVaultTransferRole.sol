pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  // todo update vault manager curator to timelock
  MoolahVault vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0xB672Ea44A1EC692A9Baf851dC90a1Ee3DB25F1C4; // timelock
  address allocator = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;
  address curator = 0xB672Ea44A1EC692A9Baf851dC90a1Ee3DB25F1C4;

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

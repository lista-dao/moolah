pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultTransferRoleDeploy is DeployBase {
  // todo update vault addresses after step 3 deployment
  MoolahVault usdtVault = MoolahVault(address(0));
  MoolahVault usdcVault = MoolahVault(address(0));

  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // timelock
  address manager = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA; // timelock
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address curator = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    _transferRoles(usdtVault, deployer);
    _transferRoles(usdcVault, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }

  function _transferRoles(MoolahVault vault, address deployer) internal {
    vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    vault.grantRole(MANAGER, manager);
    vault.grantRole(ALLOCATOR, allocator);
    vault.grantRole(CURATOR, curator);

    vault.revokeRole(CURATOR, deployer);
    vault.revokeRole(ALLOCATOR, deployer);
    vault.revokeRole(MANAGER, deployer);
    vault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
  }
}

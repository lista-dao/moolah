pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MoolahVaultFactory } from "moolah-vault/MoolahVaultFactory.sol";

/// @notice Transfers MoolahVaultFactory DEFAULT_ADMIN_ROLE from the deployer to the ETH admin
///         timelock. Run after deploy_moolahVaultFactory.sol (which initializes admin = deployer).
/// @dev Set `factory` to the deployed proxy address before running.
contract MoolahVaultFactoryTransferRoleDeploy is DeployBase {
  MoolahVaultFactory factory = MoolahVaultFactory(0x0000000000000000000000000000000000000000); // set after deploy

  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // ETH admin timelock

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

  function run() public {
    require(address(factory) != address(0), "set factory address");

    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // Hand factory admin to the ETH admin timelock, then drop the deployer's.
    factory.grantRole(DEFAULT_ADMIN_ROLE, admin);
    factory.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("transfer role done!");
  }
}

pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

/// @notice Deploys a fresh 18-decimals MoolahVault implementation on Ethereum mainnet.
/// @dev The constructor `asset` arg only fixes the immutable DECIMALS_OFFSET (USD1 has 18
///      decimals). The deployed impl address becomes MoolahVaultFactory.MOOLAH_VAULT_IMPL_18
///      on ETH: temp-edit that constant to this address and rebuild before deploying the
///      factory. See docs/runbooks/eth-moolah-vault-factory-deploy.md.
contract MoolahVaultImplDeploy is DeployBase {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70; // ETH mainnet Moolah
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // USD1 on ETH (18 decimals)

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy the 18-decimals MoolahVault implementation used by MoolahVaultFactory.
    MoolahVault impl = new MoolahVault(moolah, USD1);
    console.log("MoolahVault(18) implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

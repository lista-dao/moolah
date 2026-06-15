pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVaultFactory } from "moolah-vault/MoolahVaultFactory.sol";

/// @notice Deploys MoolahVaultFactory (implementation + ERC1967 proxy) on Ethereum mainnet.
/// @dev PREREQUISITE: MoolahVaultFactory.MOOLAH_VAULT_IMPL_18 is a compile-time constant baked
///      into bytecode. Before running this script it MUST be temp-edited to the ETH 18-dec
///      MoolahVault impl (from deploy_moolahVault_impl.sol) and the project rebuilt, otherwise
///      createMoolahVault reverts ERC1967InvalidImplementation on ETH. See
///      docs/runbooks/eth-moolah-vault-factory-deploy.md.
///      The proxy is initialized with admin = deployer (transferred to the admin timelock in a
///      follow-up step) and vaultAdmin = ETH admin timelock.
contract MoolahVaultFactoryDeploy is DeployBase {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70; // ETH mainnet Moolah
  address vaultAdmin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // ETH admin timelock

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVaultFactory implementation
    MoolahVaultFactory impl = new MoolahVaultFactory(moolah);
    console.log("MoolahVaultFactory implementation: ", address(impl));

    // Deploy MoolahVaultFactory proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, vaultAdmin)
    );
    console.log("MoolahVaultFactory proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

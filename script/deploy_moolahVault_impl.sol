pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;

  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVault implementation
    MoolahVault implWBnb = new MoolahVault(moolah, WBNB);
    console.log("MoolahVault(WBNB) implementation: ", address(implWBnb));

    vm.stopBroadcast();
  }
}

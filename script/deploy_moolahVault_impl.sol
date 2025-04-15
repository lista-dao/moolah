pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVault implementation
    MoolahVault implWBnb = new MoolahVault(moolah, WBNB);
    console.log("MoolahVault(WBNB) implementation: ", address(implWBnb));

    MoolahVault implUsd1 = new MoolahVault(moolah, USD1);
    console.log("MoolahVault(USD1) implementation: ", address(implUsd1));

    vm.stopBroadcast();
  }
}

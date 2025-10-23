pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BNBProvider } from "../src/provider/BNBProvider.sol";

contract BNBProviderDeploy is Script {
  address moolah = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address vault = 0xb6De1725f63068e45C255a2F9BbA9Efe28a4A081; // Lista WBNB Vault
  address asset = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WBNB

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BNBProvider implementation
    BNBProvider impl = new BNBProvider(moolah, vault, asset);
    console.log("BNBProvider implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

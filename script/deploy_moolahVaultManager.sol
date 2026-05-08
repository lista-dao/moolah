pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVaultManager } from "moolah-vault/MoolahVaultManager.sol";

contract MoolahVaultManagerDeploy is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address receiver = 0x09702Ea135d9D707DD51f530864f2B9220aAD87B;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVaultManager implementation
    MoolahVaultManager impl = new MoolahVaultManager(moolah);
    console.log("MoolahVaultManager implementation: ", address(impl));

    // Deploy MoolahVaultManager proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, bot, receiver, 1000 * 1e8)
    );
    console.log("MoolahVaultManager proxy: ", address(proxy));
    vm.stopBroadcast();
  }
}

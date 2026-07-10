pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultXAUtDeploy is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  // Tether Gold (XAUt) on BSC, 6 decimals
  address XAUt = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);
    MoolahVault impl = new MoolahVault(moolah, XAUt);
    console.log("MoolahVault XAUt implementation:", address(impl));
    vm.stopBroadcast();
  }
}

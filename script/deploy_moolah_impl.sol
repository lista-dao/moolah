pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Moolah } from "moolah/Moolah.sol";

contract MoolahImplDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah implementation
    Moolah impl = new Moolah();
    console.log("Moolah implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Moolah } from "moolah/Moolah.sol";

contract MoolahImplDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah implementation
    Moolah impl = new Moolah();
    console.log("Moolah implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Moolah } from "moolah/Moolah.sol";

contract MoolahImplDeploy is Script {
  address oracle = 0x79e9675cDe605Ef9965AbCE185C5FD08d0DE16B1;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah implementation
    Moolah impl = new Moolah();
    console.log("Moolah implementation: ", address(impl));

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer, oracle)
    );
    console.log("Moolah proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";

contract DeployBrokerInterestRelayerImplScript is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BrokerInterestRelayer implementation
    BrokerInterestRelayer impl = new BrokerInterestRelayer();
    console.log("BrokerInterestRelayer implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

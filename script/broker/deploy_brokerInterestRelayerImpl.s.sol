// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";

contract DeployBrokerInterestRelayerImplScript is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BrokerInterestRelayer implementation
    BrokerInterestRelayer impl = new BrokerInterestRelayer();
    console.log("BrokerInterestRelayer implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

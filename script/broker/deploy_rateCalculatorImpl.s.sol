// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";

contract DeployRateCalculatorImpl is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy RateCalculator implementation
    RateCalculator impl = new RateCalculator();
    console.log("RateCalculator implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

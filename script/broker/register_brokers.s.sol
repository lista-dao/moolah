// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";

contract RegisterBrokers is Script {
  struct RegisterConfig {
    address broker;
    uint256 minRate;
    uint256 maxRate;
  }

  RateCalculator rateCalculator;
  RegisterConfig[] brokers = [
    RegisterConfig(0x0000000000000000000000000000000000000000, 1e18, 2e18),
    RegisterConfig(0x0000000000000000000000000000000000000000, 1e18, 2e18)
  ];

  function setUp() public {
    rateCalculator = RateCalculator(vm.envAddress("RATE_CALCULATOR"));
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      RegisterConfig memory config = brokers[i];
      console.log("Registering broker: ", config.broker);
      rateCalculator.registerBroker(config.broker, config.minRate, config.maxRate);
    }

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { IBrokerLiquidator } from "../../src/liquidator/IBrokerLiquidator.sol";

contract BrokerLiquidatorAddBrokersScript is Script {
  bytes32[] marketIds = [
    bytes32(0x0000000000000000000000000000000000000000000000000000000000000000),
    bytes32(0x0000000000000000000000000000000000000000000000000000000000000000),
    bytes32(0x0000000000000000000000000000000000000000000000000000000000000000)
  ];

  address[] brokers = [
    0x0000000000000000000000000000000000000000,
    0x0000000000000000000000000000000000000000,
    0x0000000000000000000000000000000000000000
  ];

  IBrokerLiquidator brokerLiquidator;

  function setUp() public {
    brokerLiquidator = IBrokerLiquidator(vm.envAddress("BROKER_LIQUIDATOR"));
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    console.log("Adding brokers to BrokerLiquidator...");
    brokerLiquidator.batchSetMarketToBroker(marketIds, brokers, true);
    console.log("Brokers added.");

    vm.stopBroadcast();
  }
}

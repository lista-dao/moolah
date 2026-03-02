// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IBrokerInterestRelayer {
  function addBroker(address broker) external;
}

contract DeployBrokerInterestRelayer is Script {
  address[] brokers = [0xf7c4701e90867f33745F73d5edF2143f0DE03f9d];

  IBrokerInterestRelayer relayer;

  function setUp() public {
    relayer = IBrokerInterestRelayer(vm.envAddress("INTEREST_RELAYER"));
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      address broker = brokers[i];
      relayer.addBroker(broker);
      console.log("Added broker to relayer: ", broker);
    }

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IBrokerInterestRelayer {
  function addBroker(address broker) external;
}

contract DeployBrokerInterestRelayer is Script {
  address[] brokers = [0x1Fa26015286D1270343d7526C60bd57aB6bE8b54];
  address[] relayers = [0xF2D18e9201d1fE752e3115c029F0f5Ef2Ec2bdbe];

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      address broker = brokers[i];
      IBrokerInterestRelayer(relayers[i]).addBroker(broker);
      console.log("Added broker to relayer: ", broker);
    }

    vm.stopBroadcast();
  }
}

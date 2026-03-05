// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IBrokerInterestRelayer {
  function addBroker(address broker) external;
}

contract DeployBrokerInterestRelayer is Script {
  address[] brokers = [0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3, 0xa26488154D61f8977153915510564ce47a5072dD];
  address[] relayers = [0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f, 0x2A119f506ce71cF427D5ae88540fAec580840587];

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

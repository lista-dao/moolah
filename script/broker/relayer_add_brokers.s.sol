// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IBrokerInterestRelayer {
  function addBroker(address broker) external;
}

contract DeployBrokerInterestRelayer is Script {
  address[] brokers = [
    0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981,
    0xF07b74724cC734079D9D1aa22fF7591B5A32D9d2,
    0xFEb7D3Deb6a4CEE8f5da4F618098Ac943440Ff69,
    0xDf05774Cd68cE1FBaE01be3181524c904f91d628,
    0xa94d926937f29553913A50feDC365De69162613d,
    0xf9502555CC9A4D3ea557BB79b825CA10B3A8344F
  ];
  address[] relayers = [
    0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC,
    0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC,
    0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f,
    0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f,
    0x2A119f506ce71cF427D5ae88540fAec580840587,
    0x2A119f506ce71cF427D5ae88540fAec580840587
  ];

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

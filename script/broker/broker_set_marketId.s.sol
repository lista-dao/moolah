// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function setMarketId(bytes32 marketId) external;
}

contract BrokerSetMarketIdScript is Script {
  bytes32[] marketIds = [bytes32(0x226935103b730aefad53849e4cf7d92f30083cc417222f395478dabdd9ff3cac)];

  address[] brokers = [0x1Fa26015286D1270343d7526C60bd57aB6bE8b54];

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      IBroker(brokers[i]).setMarketId(marketIds[i]);
      console.log("Set marketId: ");
      console.logBytes32(marketIds[i]);
      console.log("for broker: ");
      console.logAddress(brokers[i]);
    }

    vm.stopBroadcast();
  }
}

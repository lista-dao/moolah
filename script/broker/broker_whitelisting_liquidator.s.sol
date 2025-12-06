// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IBroker {
  function toggleLiquidationWhitelist(address account, bool isAddition) external;
}

contract BrokerWhitelistLiquidatorScript is Script {
  address brokerLiquidator = address(0x0);

  address[] brokers = [
    0x0000000000000000000000000000000000000000,
    0x0000000000000000000000000000000000000000,
    0x0000000000000000000000000000000000000000
  ];

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      IBroker(brokers[i]).toggleLiquidationWhitelist(brokerLiquidator, true);
      console.log("Broker: ");
      console.logAddress(brokers[i]);
      console.log("whitelisted liquidator: ");
      console.logAddress(brokerLiquidator);
    }

    vm.stopBroadcast();
  }
}

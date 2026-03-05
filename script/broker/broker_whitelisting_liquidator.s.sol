// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function toggleLiquidationWhitelist(address account, bool isAddition) external;
}

contract BrokerWhitelistLiquidatorScript is Script {
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address[] brokers = [0xf7c4701e90867f33745F73d5edF2143f0DE03f9d];

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

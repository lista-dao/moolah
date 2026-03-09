// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function toggleLiquidationWhitelist(address account, bool isAddition) external;
}

contract BrokerWhitelistLiquidatorScript is Script {
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address[] brokers = [0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3, 0xa26488154D61f8977153915510564ce47a5072dD];

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

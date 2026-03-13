// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function toggleLiquidationWhitelist(address account, bool isAddition) external;
}

contract BrokerWhitelistLiquidatorScript is Script {
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address[] brokers = [
    0x52ee1F685ef41E8D1158E2508dC46561Ca839864,
    0xFDFc9A306084BCa33885b76d23C885dB9E3a6e72,
    0x07b72Adbe196E2E83242C3414eee5Fd7E4c0cD74,
    0x3350fC3c54CE501083a60707823833e67168bb94,
    0xCA5929B8fF8B1a4B9B8d77DFc5340977BFa425B3,
    0x306b7122adb734bD3976f6Fb7dC5E8fEf57528D7
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

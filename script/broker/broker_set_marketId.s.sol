// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function setMarketId(bytes32 marketId) external;
}

contract BrokerSetMarketIdScript is Script {
  bytes32[] marketIds = [
    bytes32(0x8de2e1f3e3935024a2667d8203983bdff70a1aee0c91665760e02c257d53032f),
    bytes32(0x95f93825819b67a64610e6adb9ac5f70d5108f5121b9df6551e23a4a7a801b5b),
    bytes32(0x6ef28e9f52ffd5e66b14ba95f3da17b782ce8c4a592218fa32f917ca10f4f054),
    bytes32(0xaaf06d7c7fd32ac1b478bdf6f068d707ea32982f299b684ef79b1023a51ad3db),
    bytes32(0xea00a233473bc0585326eec959623a054798b7543205c5079bab49015a2bf810),
    bytes32(0x76d7eaeb9d087629c477c51b13914f2489506ec25e7f494aedecee757ad539c8)
  ];

  address[] brokers = [
    0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981,
    0xF07b74724cC734079D9D1aa22fF7591B5A32D9d2,
    0xFEb7D3Deb6a4CEE8f5da4F618098Ac943440Ff69,
    0xDf05774Cd68cE1FBaE01be3181524c904f91d628,
    0xa94d926937f29553913A50feDC365De69162613d,
    0xf9502555CC9A4D3ea557BB79b825CA10B3A8344F
  ];

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

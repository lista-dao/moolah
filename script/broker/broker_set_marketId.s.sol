// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function setMarketId(bytes32 marketId) external;
}

contract BrokerSetMarketIdScript is Script {
  bytes32[] marketIds = [
    bytes32(0x864a59352d12006ab1b194176c30b0e3f538e98baf78e9ee1c0d36e852727f77),
    bytes32(0x3aeffa0dbe7aa8e3f3ae23c56f3aaf183af5f3736745a627e741cffb4ebfd6f3),
    bytes32(0x4fe11b7007a4e09f1f274bfd152b636d7d64b4637df6b645c1516b05590797db),
    bytes32(0xd6fe8c8658b8cc7e0f413b0e45e94646cc2ee9255e9500b0db0ee8c2c1499bff),
    bytes32(0x212d0a36fccb86ff79994d6094271c21149c6a65e97e5ed797429ee56f44ce64),
    bytes32(0x86e6bfa9e590d003ce03e34a79a4986120c4ced545ab62db484e43acb049c6a1)
  ];

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
      IBroker(brokers[i]).setMarketId(marketIds[i]);
      console.log("Set marketId: ");
      console.logBytes32(marketIds[i]);
      console.log("for broker: ");
      console.logAddress(brokers[i]);
    }

    vm.stopBroadcast();
  }
}

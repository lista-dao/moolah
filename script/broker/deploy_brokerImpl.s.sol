// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

contract DeployLendingBrokerImpl is DeployBase {
  // All 19 LendingBroker proxy addresses on BSC mainnet.
  address[] brokers = [
    0x6BAF9648cffB7C9c4cB7275000a27b9a7dBD59Bc,
    0x0cffd57f93190892ac2dB8A01596304268Bc2014,
    0x30DDB3A48863E4897AaCDD5D202E23270d75BaE1,
    0xf7c4701e90867f33745F73d5edF2143f0DE03f9d,
    0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3,
    0xa26488154D61f8977153915510564ce47a5072dD,
    0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981,
    0xF07b74724cC734079D9D1aa22fF7591B5A32D9d2,
    0xFEb7D3Deb6a4CEE8f5da4F618098Ac943440Ff69,
    0xDf05774Cd68cE1FBaE01be3181524c904f91d628,
    0xa94d926937f29553913A50feDC365De69162613d,
    0xf9502555CC9A4D3ea557BB79b825CA10B3A8344F,
    0x52ee1F685ef41E8D1158E2508dC46561Ca839864,
    0xFDFc9A306084BCa33885b76d23C885dB9E3a6e72,
    0x07b72Adbe196E2E83242C3414eee5Fd7E4c0cD74,
    0x3350fC3c54CE501083a60707823833e67168bb94,
    0xCA5929B8fF8B1a4B9B8d77DFc5340977BFa425B3,
    0x306b7122adb734bD3976f6Fb7dC5E8fEf57528D7,
    0x1Fa26015286D1270343d7526C60bd57aB6bE8b54
  ];
  address moolah;
  address interestRelayer;
  address oracle;

  function setUp() public {
    moolah = vm.envAddress("MOOLAH");
    interestRelayer = vm.envAddress("INTEREST_RELAYER");
    oracle = vm.envAddress("ORACLE");
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < brokers.length; i++) {
      address proxy = brokers[i];

      // Read constructor params from the existing proxy contract
      address moolah = address(LendingBroker(proxy).MOOLAH());
      address relayer = LendingBroker(proxy).RELAYER();
      address oracle = address(LendingBroker(proxy).ORACLE());

      // Deploy LendingBroker implementation
      LendingBroker impl = new LendingBroker(moolah, relayer, oracle);
      console.log("Broker proxy:", proxy);
      console.log("  New impl:  ", address(impl));
    }

    vm.stopBroadcast();
  }
}

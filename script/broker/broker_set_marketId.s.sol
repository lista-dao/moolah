// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IBroker {
  function setMarketId(bytes32 marketId) external;
}

contract BrokerSetMarketIdScript is Script {
  bytes32[] marketIds = [
    bytes32(0x1fed91636b77dab38fd796e21580718aa51e8cf89e442a0268de786adc544596),
    bytes32(0xca1432913a86b41eb10c66de79fe390b877c811a113755e9efb10f38de862450)
  ];

  address[] brokers = [0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3, 0xa26488154D61f8977153915510564ce47a5072dD];

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

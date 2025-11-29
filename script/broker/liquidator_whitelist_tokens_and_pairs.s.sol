// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { IBrokerLiquidator } from "../../src/liquidator/IBrokerLiquidator.sol";

contract BrokerLiquidatorWhitelistTokensAndPairsScript is Script {
  address[] tokens = [
    0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // WBNB
    0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B, // slisBNB
    0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c, // BTCB
    0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5 // LisUSD
  ];

  address[] pairs = [0x111111125421cA6dc452d289314280a0f8842A65, 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4];

  IBrokerLiquidator brokerLiquidator;

  function setUp() public {
    brokerLiquidator = IBrokerLiquidator(vm.envAddress("BROKER_LIQUIDATOR"));
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      console.log("Whitelisting token: ", token);
      brokerLiquidator.setTokenWhitelist(token, true);
    }

    for (uint256 i = 0; i < pairs.length; i++) {
      address pair = pairs[i];
      console.log("Whitelisting pair: ", pair);
      brokerLiquidator.setPairWhitelist(pair, true);
    }

    vm.stopBroadcast();
  }
}

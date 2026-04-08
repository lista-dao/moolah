// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

interface IBroker {
  function toggleLiquidationWhitelist(address account, bool isAddition) external;
}

contract BrokerWhitelistLiquidatorScript is DeployBase {
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address[] brokers = [
    0x305a5057DA39b0F953a03AfB2A2D74Db8020d39E, // USDT&USDC/USDT
    0x6B017339F5299dF34891AF413028DA1ab6Edbe04, // USDT&USDC/USD1
    0x38b741820B0B784840D0223056ed00708b89abCe, // USDT&USDC/U
    0xAc1c50a12a060F66a2458231B5305E0AE591D0b9, // BNB&slisBNB/USDT
    0x111A52D94791D0093B75AC4B9Ad104B7cF4AE568, // BNB&slisBNB/USD1
    0xc26CaAcb00854c5460030B0aFde60C37D9d39C79, // BNB&slisBNB/U
    0x3ade951523e81dD45e5787bb0b95Ce7341Db1287 // BNB&slisBNB/BNB
  ];

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
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

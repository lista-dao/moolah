// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

interface IBroker {
  function setMarketId(bytes32 marketId) external;
}

contract BrokerSetMarketIdScript is DeployBase {
  bytes32[] marketIds = [
    bytes32(0x6ceb64b2f43c65f4db3298ccc03a2f4c27800cc60e10d9018197ad981fcdd687), // USDT&USDC/USDT
    bytes32(0xc11c32a240a85fcd29058a6e29ae79adec9e0c4d242c21de46dd838a128bbbd2), // USDT&USDC/USD1
    bytes32(0x00a461c0ce2d3f549033b81a9c4031d4f4422e78b22238b0ff9d223c9fffa30b), // USDT&USDC/U
    bytes32(0x4a50df32dfcd7702833cf472e45f36344584725caea773c57a0f0a82d0a7ee3a), // BNB&slisBNB/USDT
    bytes32(0x303fddd3479e86023cec2a52b3b4da45c6a593067db573feb42e9ed75323349e), // BNB&slisBNB/USD1
    bytes32(0x8b3efb84b55dbdde264ae2401316bb282ca58df0f3d7600463b49ad4a1dff2f4), // BNB&slisBNB/U
    bytes32(0x34b10e29626e1829e24e44bffd0b6795eb901120d9fcb6217973a67589b3b8e4) // BNB&slisBNB/BNB
  ];

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
      IBroker(brokers[i]).setMarketId(marketIds[i]);
      console.log("Set marketId: ");
      console.logBytes32(marketIds[i]);
      console.log("for broker: ");
      console.logAddress(brokers[i]);
    }

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";


import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract LiquidatorDeploy is Script {
  // todo update allocator vault
  VaultAllocator allocator = VaultAllocator(0x9ECF66f016FCaA853FdA24d223bdb4276E5b524a);
  address vault = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    allocator.setFee(vault, 0.01 ether);

    vm.stopBroadcast();
  }
}

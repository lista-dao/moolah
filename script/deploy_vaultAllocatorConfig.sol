pragma solidity 0.8.28;

import "forge-std/Script.sol";


import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract LiquidatorDeploy is Script {
  // todo update allocator vault
  VaultAllocator allocator = VaultAllocator(0x16689558357c1F8f9104FAC5908e15FaB6a6560A);
  address vault = 0xA5edCb7c60448f7779361afc2F92f858f3A6dd1E;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    allocator.setFee(vault, 0.01 ether);

    vm.stopBroadcast();
  }
}

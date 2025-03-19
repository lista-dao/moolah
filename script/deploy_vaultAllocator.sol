pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract VaultAllocatorDeploy is Script {
  // todo: add moolah address
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;
  address admin = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy VaultAllocator implementation
    VaultAllocator impl = new VaultAllocator(moolah);
    console.log("VaultAllocator implementation: ", address(impl));

    // Deploy VaultAllocator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin)
    );
    console.log("VaultAllocator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract VaultAllocatorDeploy is Script {
  // todo: add moolah address
  address moolah = 0xb1732a5BE3812e0095de327df9DbF5044C2Fe9a2;

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
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer)
    );
    console.log("VaultAllocator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

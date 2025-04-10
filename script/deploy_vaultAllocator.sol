pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VaultAllocator } from "vault-allocator/VaultAllocator.sol";

contract VaultAllocatorDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
//  address admin = ;

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
      abi.encodeWithSelector(impl.initialize.selector, deployer)
    );
    console.log("VaultAllocator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVaultFactory } from "moolah-vault/MoolahVaultFactory.sol";

contract MoolahVaultFactoryDeploy is Script {

  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address vaultAdmin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVaultFactory implementation
    MoolahVaultFactory impl = new MoolahVaultFactory(moolah);
    console.log("MoolahVaultFactory implementation: ", address(impl));

    // Deploy MoolahVaultFactory proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, vaultAdmin)
    );
    console.log("MoolahVaultFactory proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BNBProvider } from "../src/provider/BNBProvider.sol";

contract BNBProviderDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address vault = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0; // Lista WBNB Vault
  address asset = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BNBProvider implementation
    BNBProvider impl = new BNBProvider(moolah, vault, asset);
    console.log("Loop WBNB Vault BNBProvider implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

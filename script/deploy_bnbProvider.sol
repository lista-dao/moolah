pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BNBProvider } from "../src/provider/BNBProvider.sol";

contract BNBProviderDeploy is Script {
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;
  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address wbnbVault = 0xA5edCb7c60448f7779361afc2F92f858f3A6dd1E;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BNBProvider implementation
    BNBProvider impl = new BNBProvider(moolah, wbnbVault, WBNB);
    console.log("BNBProvider implementation: ", address(impl));

    // Deploy BNBProvider proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer, deployer));
    console.log("BNBProvider proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

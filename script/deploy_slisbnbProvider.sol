pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SlisBNBProvider } from "moolah/SlisBNBProvider.sol";

contract SlisBNBProviderDeploy is Script {
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address stakeManager = 0xc695F964011a5a1024931E2AF0116afBaC41B31B;
  address clisBNB = 0x3dC5a40119B85d5f2b06eEC86a6d36852bd9aB52;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy SlisBNBProvider implementation
    SlisBNBProvider impl = new SlisBNBProvider(moolah, slisBNB, stakeManager, clisBNB);
    console.log("SlisBNBProvider implementation: ", address(impl));

    // Deploy SlisBNBProvider proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, 0.97 ether));
    console.log("SlisBNBProvider proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

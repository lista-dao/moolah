pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ETHProvider } from "../src/provider/ETHProvider.sol";

contract ETHProviderDeploy is Script {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;

  address asset = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy ETHProvider implementation
    ETHProvider impl = new ETHProvider(moolah, asset);
    console.log("ETHProvider implementation: ", address(impl));

    // Deploy ETHProvider proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer)
    );
    console.log("ETHProvider proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

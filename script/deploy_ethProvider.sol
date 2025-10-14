pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ETHProvider } from "../src/provider/ETHProvider.sol";

contract BNBProviderDeploy is Script {
  address moolah = 0x29c53B75b4CD3CeC0B58F935dC642fF47B708d65;

  address asset = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // WETH

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
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

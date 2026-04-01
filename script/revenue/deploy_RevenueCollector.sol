pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { RevenueCollector } from "revenue/RevenueCollector.sol";

contract RevenueCollectorDeploy is Script {
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  address[] pools;
  address[] liquidators;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy RevenueCollector implementation
    RevenueCollector impl = new RevenueCollector();
    console.log("RevenueCollector implementation: ", address(impl));

    // Deploy RevenueCollector proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager, bot, pools, liquidators)
    );
    console.log("RevenueCollector proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

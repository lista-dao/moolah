pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BatchManagementUtils } from "src/utils/BatchManagementUtils.sol";

contract BatchManagementUtilsDeploy is Script {
  function run() public {
    address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
    address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah implementation
    BatchManagementUtils impl = new BatchManagementUtils(moolah);
    console.log("implementation: ", address(impl));

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager)
    );
    console.log("proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";
import "./SCAddress.sol";

contract PublicLiquidatorDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PublicLiquidator implementation
    PublicLiquidator impl = new PublicLiquidator(MOOLAH);
    console.log("PublicLiquidator implementation: ", address(impl));

    // Deploy PublicLiquidator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer)
    );
    console.log("PublicLiquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

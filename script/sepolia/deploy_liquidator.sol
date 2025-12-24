pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import "./SCAddress.sol";

contract LiquidatorDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Liquidator implementation
    Liquidator impl = new Liquidator(MOOLAH);
    console.log("Liquidator implementation: ", address(impl));

    // Deploy Liquidator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer)
    );
    console.log("Liquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PositionManager } from "../../src/utils/PositionManager.sol";

contract DeployPositionManager is DeployBase {
  address constant moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address constant timelock = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PositionManager implementation
    PositionManager impl = new PositionManager(moolah, wbnb);
    console.log("PositionManager implementation: ", address(impl));

    // Deploy PositionManager proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, timelock, manager)
    );
    console.log("PositionManager proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

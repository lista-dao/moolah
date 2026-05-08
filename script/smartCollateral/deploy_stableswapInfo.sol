pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapPoolInfo } from "src/dex/StableSwapPoolInfo.sol";

contract StableSwapPoolInfoDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapPoolInfo impl = new StableSwapPoolInfo();

    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer));
    console.log("StableSwapPoolInfo proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

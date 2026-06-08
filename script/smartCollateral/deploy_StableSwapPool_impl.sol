import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "src/dex/StableSwapPool.sol";

import "./SCAddress.sol";

contract StableSwapFactoryDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapPool poolImpl = new StableSwapPool(SS_FACTORY);
    console.log("StableSwapPool impl deployed to: ", address(poolImpl));

    console.log("Set impls in Factory");
  }
}

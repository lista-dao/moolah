// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { StableSwapLPCollateral } from "../../src/dex/StableSwapLPCollateral.sol";

contract DeployStableSwapLPCollateralImpl is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // moolah address is the same for all StableSwapLPCollateral proxies
    address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    StableSwapLPCollateral impl = new StableSwapLPCollateral(moolah);
    console.log("StableSwapLPCollateral implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

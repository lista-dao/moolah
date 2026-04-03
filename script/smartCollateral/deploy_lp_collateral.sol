pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";

import "./SCAddress.sol";

contract StableSwapLPCollateralDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    string memory name = "USDC & USDT-SmartLP";

    StableSwapLPCollateral impl = new StableSwapLPCollateral(MOOLAH);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer, // admin
        deployer, // minter
        name,
        name
      )
    );
    console.log("StableSwapLPCollateral proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

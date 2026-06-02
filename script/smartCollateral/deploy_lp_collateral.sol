pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";

import "./SCAddress.sol";

// Step 2 — deploy the StableSwapLPCollateral wrapper for each new pool.
// Minter is set to the deployer here; it is re-pointed to the SmartProvider in step 3.
contract StableSwapLPCollateralDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // "USD1 & USDT-SmartLP" already deployed — only redeploy the failed one
    deployCollateral("lisUSD & USDT-SmartLP", deployer);

    vm.stopBroadcast();
  }

  function deployCollateral(string memory name, address deployer) internal {
    StableSwapLPCollateral impl = new StableSwapLPCollateral(MOOLAH);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer, // admin
        deployer, // minter (re-set to SmartProvider in step 3)
        name,
        name
      )
    );
    console.log("StableSwapLPCollateral: ", name);
    console.log("  proxy: ", address(proxy));
  }
}

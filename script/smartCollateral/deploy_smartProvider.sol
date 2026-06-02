pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";
import "./SCAddress.sol";

// Step 3 — deploy a SmartProvider for each pool and point the LP-collateral minter at it.
// Fill DEX_* (step 1) and COLLATERAL_* (step 2) in SCAddress.sol before running.
contract SmartProviderDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    deployProvider(COLLATERAL_USD1_USDT, DEX_USD1_USDT, deployer);
    deployProvider(COLLATERAL_LISUSD_USDT, DEX_LISUSD_USDT, deployer);

    vm.stopBroadcast();
  }

  function deployProvider(address smartLp, address dex, address deployer) internal {
    require(smartLp != address(0) && dex != address(0), "fill DEX_*/COLLATERAL_* in SCAddress");

    SmartProvider impl = new SmartProvider(MOOLAH, smartLp);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, dex, SS_INFO, RESILIENT_ORACLE)
    );
    console.log("SmartProvider deployed at: ", address(proxy));

    StableSwapLPCollateral(smartLp).setMinter(address(proxy));
    console.log("  minter set; lp collateral: ", smartLp);
  }
}

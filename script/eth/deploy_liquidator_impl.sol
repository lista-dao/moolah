pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { Liquidator } from "liquidator/Liquidator.sol";

/// @notice Deploy Liquidator implementation ONLY (no proxy) for ETH upgrade.
///   Usage: forge script script/eth/deploy_liquidator_impl.sol --rpc-url $ETH_RPC_URL --broadcast --verify
contract LiquidatorImplDeploy is DeployBase {
  // ETH mainnet — must match the live proxy's MOOLAH() immutable
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Liquidator implementation only — no proxy
    // New storage: fundSource (default 0 = legacy) + reflowBlacklist mapping (default empty)
    // No re-init needed — zero values preserve legacy behavior.
    Liquidator impl = new Liquidator(moolah);
    console.log("Liquidator implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

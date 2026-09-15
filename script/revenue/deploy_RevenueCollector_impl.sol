// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { RevenueCollector } from "revenue/RevenueCollector.sol";

/// @notice BSC mainnet: Deploy a new RevenueCollector implementation only.
///         The proxy upgrade to this impl is performed separately (via the
///         Timelock / Safe that holds DEFAULT_ADMIN_ROLE on the proxy).
///
///   Usage:
///     source .env && forge script script/revenue/deploy_RevenueCollector_impl.sol \
///       --rpc-url $BSC_RPC --broadcast --verify --via-ir -vvv
contract RevenueCollectorImplDeploy is DeployBase {
  function run() public {
    require(block.chainid == 56, "not BSC mainnet");

    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    console.log("Chain ID: ", block.chainid);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy RevenueCollector implementation
    RevenueCollector impl = new RevenueCollector();
    console.log("RevenueCollector implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

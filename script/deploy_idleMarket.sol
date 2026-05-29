// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { DeployBase } from "./DeployBase.sol";
import { IdleCollateralToken } from "../src/utils/IdleCollateralToken.sol";
import { IdleOracle } from "../src/oracle/IdleOracle.sol";

/// @notice Deploys IdleCollateralToken + IdleOracle on BSC mainnet. Singletons — one deployment
///         is shared across every idle market.
contract DeployIdleMarket is DeployBase {
  // BSC mainnet resilient oracle (multiOracle).
  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  function run() public {
    uint256 deployerKey = _deployerKey();
    address deployer = vm.addr(deployerKey);
    console.log("Deployer:", deployer);
    console.log("Chain id:", block.chainid);

    vm.startBroadcast(deployerKey);

    IdleCollateralToken idleCollateral = new IdleCollateralToken();
    console.log("IdleCollateralToken:", address(idleCollateral));

    IdleOracle idleOracle = new IdleOracle(address(idleCollateral), RESILIENT_ORACLE);
    console.log("IdleOracle:        ", address(idleOracle));

    vm.stopBroadcast();
  }
}

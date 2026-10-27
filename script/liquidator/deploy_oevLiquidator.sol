// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OEVLiquidator } from "liquidator/OEVLiquidator.sol";

/// @dev Deploys the OEVLiquidator (impl + UUPS proxy) with final roles set in initialize, so the
///      deployer never holds any role.
contract OEVLiquidatorDeploy is DeployBase {
  address moolah;
  address timelock;
  address manager;
  address pauser;
  address oev;

  function setUp() public {
    moolah = vm.envAddress("MOOLAH");
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
    pauser = vm.envAddress("PAUSER");
    oev = vm.envAddress("OEV");
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy OEVLiquidator implementation
    OEVLiquidator impl = new OEVLiquidator(moolah);
    console.log("OEVLiquidator implementation: ", address(impl));

    // Deploy OEVLiquidator proxy. initialize(admin, manager, pauser, oev).
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, timelock, manager, pauser, oev)
    );
    console.log("OEVLiquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

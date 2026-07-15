pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MarketFactory } from "../../src/moolah/MarketFactory.sol";

contract MarketFactoryTransferRoleDeploy is DeployBase {
  MarketFactory marketFactory = MarketFactory(0xA2ff080D4c0b71B6c8796129DD4aCc0B09D7592c);
  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // ETH TimeLock

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    marketFactory.grantRole(DEFAULT_ADMIN_ROLE, admin);
    marketFactory.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

contract DeployLendingBrokerImpl is Script {
  address moolah;
  address interestRelayer;
  address oracle;

  function setUp() public {
    moolah = vm.envAddress("MOOLAH");
    interestRelayer = vm.envAddress("INTEREST_RELAYER");
    oracle = vm.envAddress("ORACLE");
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy LendingBroker implementation
    LendingBroker impl = new LendingBroker(moolah, interestRelayer, oracle);
    console.log("LendingBroker implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IAccessControl {
  function renounceRole(bytes32 role, address callerConfirmation) external;
}

contract RenounceRolesScript is Script {
  address[] brokers = [0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3, 0xa26488154D61f8977153915510564ce47a5072dD];

  address[] replayers = [0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f, 0x2A119f506ce71cF427D5ae88540fAec580840587];

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // renounce roles from brokers
    for (uint256 i = 0; i < brokers.length; i++) {
      IAccessControl(brokers[i]).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
      console.log("Renounced DEFAULT_ADMIN_ROLE from broker: ", brokers[i]);
      IAccessControl(brokers[i]).renounceRole(MANAGER, deployer);
      console.log("Renounced MANAGER role from broker: ", brokers[i]);
    }

    // renounce roles from brokerInterestRelayer
    for (uint256 i = 0; i < replayers.length; i++) {
      address brokerInterestRelayer = replayers[i];
      IAccessControl(brokerInterestRelayer).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
      console.log("Renounced DEFAULT_ADMIN_ROLE from brokerInterestRelayer");
      IAccessControl(brokerInterestRelayer).renounceRole(MANAGER, deployer);
      console.log("Renounced MANAGER role from brokerInterestRelayer");
    }

    vm.stopBroadcast();
  }
}

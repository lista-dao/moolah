// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IAccessControl {
  function renounceRole(bytes32 role, address callerConfirmation) external;
}

contract RenounceRolesScript is Script {
  address[] brokers = [0xf7c4701e90867f33745F73d5edF2143f0DE03f9d];

  address brokerInterestRelayer = 0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // renounce roles from brokers
    for (uint256 i = 0; i < brokers.length; i++) {
      IAccessControl(brokers[i]).renounceRole(DEFAULT_ADMIN_ROLE, brokers[i]);
      console.log("Renounced DEFAULT_ADMIN_ROLE from broker: ", brokers[i]);
      IAccessControl(brokers[i]).renounceRole(MANAGER, brokers[i]);
      console.log("Renounced MANAGER role from broker: ", brokers[i]);
    }

    // renounce roles from brokerInterestRelayer
    IAccessControl(brokerInterestRelayer).renounceRole(DEFAULT_ADMIN_ROLE, brokerInterestRelayer);
    console.log("Renounced DEFAULT_ADMIN_ROLE from brokerInterestRelayer");
    IAccessControl(brokerInterestRelayer).renounceRole(MANAGER, brokerInterestRelayer);
    console.log("Renounced MANAGER role from brokerInterestRelayer");

    vm.stopBroadcast();
  }
}

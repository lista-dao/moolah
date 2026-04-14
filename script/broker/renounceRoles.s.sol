// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

interface IAccessControl {
  function renounceRole(bytes32 role, address callerConfirmation) external;
}

contract RenounceRolesScript is Script {
  address[] brokers = [
    0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981,
    0xF07b74724cC734079D9D1aa22fF7591B5A32D9d2,
    0xFEb7D3Deb6a4CEE8f5da4F618098Ac943440Ff69,
    0xDf05774Cd68cE1FBaE01be3181524c904f91d628,
    0xa94d926937f29553913A50feDC365De69162613d,
    0xf9502555CC9A4D3ea557BB79b825CA10B3A8344F
  ];
  address[] replayers;

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

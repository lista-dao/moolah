// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IAccessControl {
  function renounceRole(bytes32 role, address callerConfirmation) external;
}

contract RenounceRolesScript is Script {
  address[] brokers = [
    0x6BAF9648cffB7C9c4cB7275000a27b9a7dBD59Bc,
    0x0cffd57f93190892ac2dB8A01596304268Bc2014,
    0x30DDB3A48863E4897AaCDD5D202E23270d75BaE1
  ];

  address brokerInterestRelayer = 0xcb2590F10728e3ffc725d7ECf88EcFd0d92c9d6a;
  address rateCalculator = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

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

    // renounce roles from rateCalculator
    IAccessControl(rateCalculator).renounceRole(DEFAULT_ADMIN_ROLE, rateCalculator);
    console.log("Renounced DEFAULT_ADMIN_ROLE from rateCalculator");
    IAccessControl(rateCalculator).renounceRole(MANAGER, rateCalculator);
    console.log("Renounced MANAGER role from rateCalculator");

    // renounce roles from brokerLiquidator
    IAccessControl(brokerLiquidator).renounceRole(DEFAULT_ADMIN_ROLE, brokerLiquidator);
    console.log("Renounced DEFAULT_ADMIN_ROLE from brokerLiquidator");
    IAccessControl(brokerLiquidator).renounceRole(MANAGER, brokerLiquidator);
    console.log("Renounced MANAGER role from brokerLiquidator");

    vm.stopBroadcast();
  }
}

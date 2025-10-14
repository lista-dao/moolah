pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { FixedRateIrm } from "interest-rate-model/FixedRateIrm.sol";

contract FixedRateIrmTransferRoleDeploy is Script {
  FixedRateIrm irm = FixedRateIrm(0x9A7cA2CfB886132B6024789163e770979E4222e1);
  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    irm.grantRole(DEFAULT_ADMIN_ROLE, admin);
    irm.grantRole(MANAGER, manager);

    irm.revokeRole(MANAGER, deployer);
    irm.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

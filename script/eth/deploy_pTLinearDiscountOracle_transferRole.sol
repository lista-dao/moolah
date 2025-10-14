pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { PTLinearDiscountOracle } from "../../src/oracle/PTLinearDiscountOracle.sol";

contract PTLinearDiscountOracleTransferRoleDeploy is Script {
  PTLinearDiscountOracle irm = PTLinearDiscountOracle(0xb169d2459F51d02d7fC8A39498ec2801652b594c);
  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    irm.grantRole(DEFAULT_ADMIN_ROLE, admin);

    irm.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

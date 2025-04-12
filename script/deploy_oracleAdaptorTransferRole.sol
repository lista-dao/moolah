pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { OracleAdaptor } from "src/oracle/OracleAdaptor.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  OracleAdaptor oracleAdaptor = OracleAdaptor(0x21650E416dC6C89486B2E654c86cC2c36c597b58);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    oracleAdaptor.grantRole(DEFAULT_ADMIN_ROLE, admin);
    oracleAdaptor.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

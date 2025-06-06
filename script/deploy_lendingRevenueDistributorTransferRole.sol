pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { LendingRevenueDistributor } from "src/revenue/LendingRevenueDistributor.sol";

contract MoolahVaultTransferRoleDeploy is Script {
  LendingRevenueDistributor lendingRevenueDistributor =
    LendingRevenueDistributor(payable(0xea55952a51ddd771d6eBc45Bd0B512276dd0b866));
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // b0c6

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    lendingRevenueDistributor.grantRole(DEFAULT_ADMIN_ROLE, admin);
    lendingRevenueDistributor.grantRole(MANAGER, manager);

    lendingRevenueDistributor.revokeRole(MANAGER, deployer);
    lendingRevenueDistributor.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

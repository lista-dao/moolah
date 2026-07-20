pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LendingRevenueDistributor } from "src/revenue/LendingRevenueDistributor.sol";

contract LendingRevenueDistributorTransferRoleDeploy is DeployBase {
  LendingRevenueDistributor lendingRevenueDistributor =
    LendingRevenueDistributor(payable(0x0fe5741e8dFe53618c4056F745fad531118640D9)); // ETH ListaRevenueDistributor proxy
  address marketFactory = 0xA2ff080D4c0b71B6c8796129DD4aCc0B09D7592c; // ETH MarketFactory proxy
  address managerSafe = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // Manager Safe (3/6)

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    console.log("MarketFactory: ", marketFactory);
    console.log("Manager Safe: ", managerSafe);
    vm.startBroadcast(deployerPrivateKey);

    // TX 1: Grant DEFAULT_ADMIN_ROLE to MarketFactory (Grant A)
    lendingRevenueDistributor.grantRole(DEFAULT_ADMIN_ROLE, marketFactory);

    // TX 1b-1: Grant DEFAULT_ADMIN_ROLE to Manager Safe
    lendingRevenueDistributor.grantRole(DEFAULT_ADMIN_ROLE, managerSafe);

    // TX 1b-2: Deployer renounces its own DEFAULT_ADMIN_ROLE
    // IMPORTANT: must be AFTER granting Manager Safe, otherwise roles become unmanageable
    lendingRevenueDistributor.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("TX 1 + TX 1b done!");
    console.log("Verify:");
    console.log("  hasRole(DEFAULT_ADMIN_ROLE, MarketFactory) == true");
    console.log("  hasRole(DEFAULT_ADMIN_ROLE, Manager Safe)  == true");
    console.log("  hasRole(DEFAULT_ADMIN_ROLE, deployer)      == false");
  }
}

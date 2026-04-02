pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract LiquidatorTransferRoleDeploy is DeployBase {
  // using MarketParamsLib for MarketParams;
  Liquidator liquidator = Liquidator(payable(0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C));

  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    liquidator.grantRole(DEFAULT_ADMIN_ROLE, admin);
    liquidator.grantRole(MANAGER, manager);

    liquidator.revokeRole(MANAGER, deployer);
    liquidator.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

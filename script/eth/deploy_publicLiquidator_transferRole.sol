pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";

contract LiquidatorTransferRoleDeploy is Script {
  PublicLiquidator liquidator = PublicLiquidator(payable(0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5));

  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
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

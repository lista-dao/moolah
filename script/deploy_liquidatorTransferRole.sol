pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract LiquidatorConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo
  Liquidator liquidator = Liquidator(payable(0x65c559d41904a43cCf7bd9BF7B5B34896a39EBea));

  address admin = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address manager = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

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

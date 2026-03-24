pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { MarketFactory } from "../src/moolah/MarketFactory.sol";

contract MarketFactoryTransferRoleDeploy is Script {
  MarketFactory marketFactory = MarketFactory(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    marketFactory.grantRole(DEFAULT_ADMIN_ROLE, admin);
    marketFactory.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

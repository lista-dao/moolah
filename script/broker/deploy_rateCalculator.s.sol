// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";

contract DeployRateCalculator is Script {
  address timelock;
  address manager;
  address pauser;
  address bot;

  function setUp() public {
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
    pauser = vm.envAddress("PAUSER");
    bot = vm.envAddress("BOT");
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy RateCalculator implementation
    RateCalculator impl = new RateCalculator();
    console.log("RateCalculator implementation: ", address(impl));

    // Deploy RateCalculator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, pauser, bot)
    );
    console.log("RateCalculator proxy: ", address(proxy));

    // grant roles to manager and admin
    bytes32 MANAGER = keccak256("MANAGER");
    bytes32 DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    RateCalculator(address(proxy)).grantRole(MANAGER, manager);
    RateCalculator(address(proxy)).grantRole(DEFAULT_ADMIN_ROLE, timelock);

    vm.stopBroadcast();
  }
}

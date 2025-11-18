// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedRateIrm } from "../src/interest-rate-model/FixedRateIrm.sol";

contract DeployFixedRateIRM is Script {
  address timelock;
  address manager;

  function setUp() public {
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy FixedRateIRM implementation
    FixedRateIrm impl = new FixedRateIrm();
    console.log("FixedRateIRM implementation: ", address(impl));

    // Deploy FixedRateIRM proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer)
    );
    console.log("FixedRateIRM proxy: ", address(proxy));

    // grant roles to manager and admin
    bytes32 MANAGER = keccak256("MANAGER");
    bytes32 DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    FixedRateIrm(address(proxy)).grantRole(MANAGER, manager);
    FixedRateIrm(address(proxy)).grantRole(DEFAULT_ADMIN_ROLE, timelock);

    vm.stopBroadcast();
  }
}

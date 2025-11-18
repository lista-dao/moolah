// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";

contract DeployBrokerInterestRelayer is Script {
  address timelock;
  address manager;
  address moolah;
  address vault;
  address token;

  function setUp() public {
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
    token = vm.envAddress("LOAN_TOKEN");
    vault = vm.envAddress("VAULT");
    moolah = vm.envAddress("MOOLAH");
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BrokerInterestRelayer implementation
    BrokerInterestRelayer impl = new BrokerInterestRelayer();
    console.log("BrokerInterestRelayer implementation: ", address(impl));

    // Deploy BrokerInterestRelayer proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, moolah, vault, token)
    );
    console.log("BrokerInterestRelayer proxy: ", address(proxy));

    // grant roles to manager and admin
    bytes32 MANAGER = keccak256("MANAGER");
    bytes32 DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    BrokerInterestRelayer(address(proxy)).grantRole(MANAGER, manager);
    BrokerInterestRelayer(address(proxy)).grantRole(DEFAULT_ADMIN_ROLE, timelock);

    vm.stopBroadcast();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditBrokerInterestRelayer } from "../../src/broker/CreditBrokerInterestRelayer.sol";

contract DeployBrokerInterestRelayer is Script {
  address moolah_testnet = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address vault = 0x22f0223C503b544b547f825a3eB509FB1406a313;
  address u_testnet = 0x1f7E0B2883573fe590c10Bf4eAE358E1fBd7c4aa;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditBrokerInterestRelayer implementation
    CreditBrokerInterestRelayer impl = new CreditBrokerInterestRelayer();
    console.log("CreditBrokerInterestRelayer implementation: ", address(impl));

    // Deploy CreditBrokerInterestRelayer proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, moolah_testnet, vault, u_testnet)
    );
    console.log("CreditBrokerInterestRelayer proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

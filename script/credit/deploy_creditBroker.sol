// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditBroker } from "../../src/broker/CreditBroker.sol";

contract DeployCreditBroker is Script {
  address moolah_testnet = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address interestRelayer = 0x6405f9c4bD7cb98817EEc9Fdf65407D1040A3fD1;
  address oracle = 0x79e9675cDe605Ef9965AbCE185C5FD08d0DE16B1;
  uint256 maxFixedLoanPositions = 10;
  address lista_testnet = 0x90b94D605E069569Adf33C0e73E26a83637c94B1;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditBroker implementation
    CreditBroker impl = new CreditBroker(moolah_testnet, interestRelayer, oracle, lista_testnet);
    console.log("CreditBroker implementation: ", address(impl));

    // Deploy CreditBroker proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer, deployer, maxFixedLoanPositions)
    );
    console.log("CreditBroker proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

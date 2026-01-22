// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditBrokerInfo } from "../../src/broker/CreditBrokerInfo.sol";

contract DeployCreditBrokerInfo is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditBrokerInfo implementation
    CreditBrokerInfo impl = new CreditBrokerInfo();
    console.log("CreditBrokerInfo implementation: ", address(impl));

    // Deploy CreditBrokerInfo proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer));

    console.log("CreditBrokerInfo proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

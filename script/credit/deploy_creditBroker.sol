// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditBroker } from "../../src/broker/CreditBroker.sol";

contract DeployCreditBroker is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address interestRelayer = 0xBd94C4E931c1a15941B6273A952Af322891adC47;
  address oracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address lista = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;
  address creditToken = 0x1f9831626CE85909794eEaA5C35BF34DB3eB52d8;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditBroker implementation
    CreditBroker impl = new CreditBroker(moolah, interestRelayer, oracle, lista, creditToken);
    console.log("CreditBroker implementation: ", address(impl));

    // Deploy CreditBroker proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer, deployer)
    );
    console.log("CreditBroker proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

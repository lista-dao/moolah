// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditBrokerInterestRelayer } from "../../src/broker/CreditBrokerInterestRelayer.sol";

contract DeployBrokerInterestRelayer is Script {
  address vault = 0x4E82Fa869F8D05c8F94900d4652Fdb82f3C7A004;
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address _u = 0xcE24439F2D9C6a2289F741120FE202248B666666;
  address lista = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditBrokerInterestRelayer implementation
    CreditBrokerInterestRelayer impl = new CreditBrokerInterestRelayer();
    console.log("CreditBrokerInterestRelayer implementation: ", address(impl));

    // Deploy CreditBrokerInterestRelayer proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, moolah, vault, _u, lista)
    );
    console.log("CreditBrokerInterestRelayer proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

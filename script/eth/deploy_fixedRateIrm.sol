pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { FixedRateIrm } from "interest-rate-model/FixedRateIrm.sol";
import { Moolah } from "moolah/Moolah.sol";

contract FixedRateIrmDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy InterestRateModel implementation
    FixedRateIrm impl = new FixedRateIrm();
    console.log("FixedRateIrm implementation: ", address(impl));
    // Deploy InterestRateModel proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer)
    );
    console.log("InterestRateModel proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

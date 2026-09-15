pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { FixedRateIrm } from "interest-rate-model/FixedRateIrm.sol";
import { Moolah } from "moolah/Moolah.sol";

contract FixedRateIrmDeploy is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy InterestRateModel implementation
    FixedRateIrm impl = new FixedRateIrm(moolah);
    console.log("FixedRateIrm implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

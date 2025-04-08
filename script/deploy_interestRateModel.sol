pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";
import { Moolah } from "moolah/Moolah.sol";

contract InterestRateModelDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
//  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy InterestRateModel implementation
    InterestRateModel impl = new InterestRateModel(moolah);
    console.log("InterestRateModel implementation: ", address(impl));

    // Deploy InterestRateModel proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer));
    console.log("InterestRateModel proxy: ", address(proxy));

    // enable irm
    Moolah(moolah).enableIrm(address(proxy));

    vm.stopBroadcast();
  }
}

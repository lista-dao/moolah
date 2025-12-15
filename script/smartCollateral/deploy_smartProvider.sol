pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";
import "./SCAddress.sol";

contract SmartProviderDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    address smartLp = 0x627B5567458A76e6B6a6a6BBe3FcFF7f81821a58;
    address dex = 0xd77e86779022227226377Dc30D03CF1C78439AcF;

    // Deploy SmartProvider
    SmartProvider impl = new SmartProvider(MOOLAH, smartLp);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, dex, SS_INFO, RESILIENT_ORACLE)
    );

    console.log("SmartProvider deployed at: ", address(proxy));

    // set minter to smart provider
    StableSwapLPCollateral(smartLp).setMinter(address(proxy));
    console.log("Minter set to SmartProvider");

    vm.stopBroadcast();
  }
}

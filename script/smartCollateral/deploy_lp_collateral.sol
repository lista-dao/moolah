pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";

import "./SCAddress.sol";

contract StableSwapLPCollateralDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapLPCollateral impl = new StableSwapLPCollateral(MOOLAH);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer, // admin
        deployer, // minter
        "BTCB & solvBTC-SmartLP", // name
        "BTCB & solvBTC-SmartLP" // symbol
      )
    );
    console.log("StableSwapLPCollateral proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

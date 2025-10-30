pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";

contract LiquidatorDeploy is Script {
  address moolah = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  //  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Liquidator implementation
    PublicLiquidator impl = new PublicLiquidator(moolah);
    console.log("PublicLiquidator implementation: ", address(impl));

    // Deploy Liquidator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer)
    );
    console.log("PublicLiquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

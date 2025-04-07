pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Liquidator } from "liquidator/Liquidator.sol";

contract LiquidatorDeploy is Script {
  // todo: update moolah address
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;
  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Liquidator implementation
    Liquidator impl = new Liquidator(moolah);
    console.log("Liquidator implementation: ", address(impl));

    // Deploy Liquidator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, bot)
    );
    console.log("Liquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";

contract PublicLiquidatorDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PublicLiquidator implementation
    PublicLiquidator impl = new PublicLiquidator(moolah);
    console.log("PublicLiquidator implementation: ", address(impl));

    // Deploy PublicLiquidator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, bot)
    );
    console.log("PublicLiquidator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";
import "./SCAddress.sol";

contract SmartProviderDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy SmartProvider
    SmartProvider impl = new SmartProvider(MOOLAH, COLLATERAL_USD1_USDT);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, DEX_USD1_USDT, SS_INFO, RESILIENT_ORACLE)
    );

    console.log("SmartProvider deployed at: ", address(proxy));

    // set minter to smart provider
    StableSwapLPCollateral(COLLATERAL_USD1_USDT).setMinter(address(proxy));
    console.log("Minter set to SmartProvider");

    vm.stopBroadcast();
  }
}

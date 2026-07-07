pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";

/// @dev Deploys the LiquidationVault (impl + UUPS proxy). Roles are initialized to the deployer and
///      then handed over via a separate transfer-role script (mirrors deploy_liquidator flow).
contract LiquidationVaultDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy LiquidationVault implementation
    LiquidationVault impl = new LiquidationVault();
    console.log("LiquidationVault implementation: ", address(impl));

    // Deploy LiquidationVault proxy. initialize(admin, manager, pauser, bot).
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer, deployer)
    );
    console.log("LiquidationVault proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

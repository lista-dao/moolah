pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is DeployBase {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;

  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  struct VaultConfig {
    address asset;
    string name;
    string symbol;
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    VaultConfig[] memory configs = new VaultConfig[](1);
    configs[0] = VaultConfig({ asset: WETH, name: "Lista WETH Savings Vault", symbol: "ListaSafeWETH" });

    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < configs.length; i++) {
      VaultConfig memory c = configs[i];
      console.log("Deploying vault:", c.name);

      MoolahVault impl = new MoolahVault(moolah, c.asset);
      console.log("  implementation:", address(impl));

      ERC1967Proxy proxy = new ERC1967Proxy(
        address(impl),
        abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, c.asset, c.name, c.symbol)
      );
      console.log("  proxy:", address(proxy));
    }
    vm.stopBroadcast();
  }
}

pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is DeployBase {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;

  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  struct VaultConfig {
    address asset;
    string name;
    string symbol;
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    VaultConfig[] memory configs = new VaultConfig[](2);
    configs[0] = VaultConfig({ asset: USDT, name: "Lista USDT Savings Vault", symbol: "ListaSafeUSDT" });
    configs[1] = VaultConfig({ asset: USDC, name: "Lista USDC Savings Vault", symbol: "ListaSafeUSDC" });

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

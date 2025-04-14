pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address asset = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // USD1
  string name = "Lista USD1 Vault";
  string symbol = "ListaUSD1";
  address vaultAllocator = 0x9ECF66f016FCaA853FdA24d223bdb4276E5b524a;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVault implementation
    MoolahVault impl = new MoolahVault(moolah, asset);
    console.log("MoolahVault implementation: ", address(impl));

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, asset, name, symbol)
    );
    console.log("MoolahVault proxy: ", address(proxy));

    MoolahVault vault = MoolahVault(address(proxy));
    // setup roles
    vault.grantRole(vault.ALLOCATOR(), vaultAllocator);

    console.log("setup ALLOCATOR role done!");
    vm.stopBroadcast();
  }
}

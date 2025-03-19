pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  // todo
  address moolah = 0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975;
  address asset = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WBNB
  string name = "Lista DAO BNB Vault";
  string symbol = "ListaBNB";
  address vaultAllocator = 0x16689558357c1F8f9104FAC5908e15FaB6a6560A;

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

    console.log("setup role done!");
    vm.stopBroadcast();
  }
}

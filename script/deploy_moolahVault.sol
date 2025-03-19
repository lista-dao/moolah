pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  // todo
  address moolah = 0xb1732a5BE3812e0095de327df9DbF5044C2Fe9a2;
  address asset = 0x6858f3fe341f8A8D3bC922D52EBe12C0ee5d1C59; // pumpBTC
  string name = "Test Name";
  string symbol = "Test Symbol";
  address admin = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address manager = 0x7f8216700007c832a91AC0d997d6b246769948Ea; // timelock
  address curator = 0x7f8216700007c832a91AC0d997d6b246769948Ea; // timelock
  address allocator = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

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
    vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), admin);
    vault.grantRole(vault.MANAGER(), manager);
    vault.grantRole(vault.CURATOR(), curator);
    vault.grantRole(vault.ALLOCATOR(), allocator);

    vault.revokeRole(vault.MANAGER(), deployer);
    vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

    console.log("setup role done!");
    vm.stopBroadcast();
  }
}

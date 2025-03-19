pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0xb1732a5BE3812e0095de327df9DbF5044C2Fe9a2;
  address asset = 0x6858f3fe341f8A8D3bC922D52EBe12C0ee5d1C59; // pumpBTC

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
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, asset, "lista usdt vault", "lUSDT")
    );
    console.log("MoolahVault proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

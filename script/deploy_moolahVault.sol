pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address CDL = 0x84575b87395c970F1F48E87d87a8dB36Ed653716; // CDL

  MoolahVault impl = MoolahVault(0xA1f832c7C7ECf91A53b4ff36E0ABdb5133C15982);
  string name = "CDL Vault";
  string symbol = "CDL";

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, CDL, name, symbol)
    );
    console.log("MoolahVault proxy: ", address(proxy));
    vm.stopBroadcast();
  }
}

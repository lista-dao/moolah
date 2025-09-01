pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address OIK = 0xB035723D62e0e2ea7499D76355c9D560f13ba404;
  address EGL1 = 0xf4B385849f2e817E92bffBfB9AEb48F950Ff4444;

  MoolahVault impl = MoolahVault(0xA1f832c7C7ECf91A53b4ff36E0ABdb5133C15982);

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    address abProxy = deployVault(deployer, OIK, "OIK Vault", "AB");
    address bProxy = deployVault(deployer, EGL1, "EGL1 Vault", "B");

    console.log("OIK Vault proxy: ", abProxy);
    console.log("EGL1 Vault proxy: ", bProxy);
    vm.stopBroadcast();
  }

  function deployVault(
    address deployer,
    address asset,
    string memory name,
    string memory symbol
  ) internal returns (address) {
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, asset, name, symbol)
    );
    return address(proxy);
  }
}

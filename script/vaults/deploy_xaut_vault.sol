pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { DeployBase } from "script/DeployBase.sol";
import { console } from "forge-std/console.sol";

contract DeployXautVault is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address XAUT = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy new MoolahVault implementation for XAUT
    MoolahVault impl = new MoolahVault(moolah, XAUT);
    console.log("MoolahVault impl: ", address(impl));

    // Deploy XAUT Vault proxy
    ERC1967Proxy xautProxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, XAUT, "Lista XAUT Vault", "lisXAUT")
    );
    console.log("XAUT Vault proxy: ", address(xautProxy));

    vm.stopBroadcast();
  }
}

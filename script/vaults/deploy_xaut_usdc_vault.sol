pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { DeployBase } from "script/DeployBase.sol";
import { console } from "forge-std/console.sol";

contract DeployXautUsdcVault is DeployBase {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  MoolahVault impl = MoolahVault(0x8F9475F2F5fEcccce21A14971DdE47498C2e51C3);

  address XAUT = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;
  address USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy XAUT Vault
    ERC1967Proxy xautProxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, XAUT, "Lista XAUT Vault", "Lista XAUT Vault")
    );
    console.log("XAUT Vault proxy: ", address(xautProxy));

    // Deploy USDC Vault
    ERC1967Proxy usdcProxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, USDC, "Lista USDC Vault", "Lista USDC Vault")
    );
    console.log("USDC Vault proxy: ", address(usdcProxy));

    vm.stopBroadcast();
  }
}

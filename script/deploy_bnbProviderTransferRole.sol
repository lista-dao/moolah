pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BNBProvider } from "../src/provider/BNBProvider.sol";

contract BNBProviderTransferRoleDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  BNBProvider provider = BNBProvider(payable(0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0)); // Loop WBNB Vault

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    provider.grantRole(DEFAULT_ADMIN_ROLE, admin);
    provider.grantRole(MANAGER, manager);

    provider.revokeRole(MANAGER, deployer);
    provider.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();
  }
}

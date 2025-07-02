pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;

  MoolahVault impl = MoolahVault(0xAaB62068D44C3b4D4214fb1d4645c071D978a777);

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    address wbnbProxy = deployVault(deployer, WBNB, "Solv-Exclusive BNB Vault", "SolvBNB");
    address usd1Proxy = deployVault(deployer, USD1, "Solv-Exclusive USD1 Vault", "SolvUSD1");

    console.log("WBNB Vault proxy: ", wbnbProxy);
    console.log("USD1 Vault proxy: ", usd1Proxy);
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

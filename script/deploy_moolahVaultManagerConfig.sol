pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVaultManager } from "moolah-vault/MoolahVaultManager.sol";

contract MoolahVaultManagerConfigDeploy is DeployBase {
  MoolahVaultManager vaultManager = MoolahVaultManager(0x0000000000000000000000000000000000000000);

  address[] vaults = [
    0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0,
    0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627,
    0xE46b8E65006e6450bdd8cb7D3274AB4F76f4C705,
    0x6d6783C146F2B0B2774C1725297f1845dc502525,
    0xaB251dc87dc313649D024bd69b34c8E7690Ce1fc,
    0x2Fa11Fc42e7fdFF98e1D043992Db5e10123A41B0,
    0x60eeD309f259050b40B234D105329A4Fd2F91163,
    0xE27433EE40CFc59B4881b3C37B8e908EA0550aA7,
    0xEE161d34F7a12EA3edeA853AA849783d4b51b5b5,
    0x8703d3ABeA5CCf31c6E13B9C05558b1f4666F183,
    0x34a436478d34cEE558DB242e7A0F1676bD84Ca45,
    0x52844A906C9A5103ee99C293a2EE181Ce16a6743,
    0xf21308b903F96592B6d6988c646dC2A3028F39fd,
    0x384729E442b7636709896e9a3bEf63EF70C22FB0,
    0x68e83cA4c2869fC6E92774E549FF9d547EAE24Ab,
    0x2CB60a0E6c2a5fF4249eB890E267B660C6676Cc6,
    0xE03D86e5Baa3509AC4A059A41737bAa8169B6529,
    0x9A17Fd5Cb8EFc25d11567e713aE795A89775a759
  ];

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);
    vaultManager.batchSetVaultWhitelist(vaults, true);
    vm.stopBroadcast();
    console.log("set vault whitelist done!");
  }
}

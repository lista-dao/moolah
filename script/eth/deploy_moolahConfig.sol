pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Moolah } from "moolah/Moolah.sol";

contract MoolahConfigDeploy is Script {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address lendingFeeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  address fixedRateIrm = 0x9A7cA2CfB886132B6024789163e770979E4222e1;

  uint256 lltv86 = 0.86 ether;
  uint256 lltv915 = 0.915 ether;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    Moolah(moolah).setFeeRecipient(lendingFeeRecipient);
    Moolah(moolah).setDefaultMarketFee(0.1 ether);

    Moolah(moolah).enableLltv(lltv86);
    Moolah(moolah).enableLltv(lltv915);

    Moolah(moolah).enableIrm(irm);
    Moolah(moolah).enableIrm(fixedRateIrm);

    Moolah(moolah).grantRole(Moolah(moolah).OPERATOR(), deployer);

    vm.stopBroadcast();
  }
}

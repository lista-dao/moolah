// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarketFactory } from "../../src/moolah/MarketFactory.sol";

contract MarketFactoryDeploy is DeployBase {
  address moolah = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address liquidator = 0x8096Bbe78eB83B83dD286c6062a1eFbE85305c97;
  address publicLiquidator = 0x456500a836DD73A5aF6fD85632E4805a8dAb9a97;
  address listaRevenueDistributor = 0xe36857af784fB2B8cFA22481b51Fa0c99D13fF20;
  address buyback = 0x371b76E7C797AF9336443F6588B510c9d177315e;
  address autoBuyback = 0xa4cb526E4D1CaF21f1DFA824f9B4728b217D1eBd;
  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address BNBProvider = 0x297152bCC1dd5bC0Df527CB16E7Ff7348d7b1d72;
  address slisBNBProvider = 0x0612c940460D68C16aA213315E32Fba579beD6A6;
  address rateCalculator = 0x638B87aBD83C54CBaABBDfF096f94F795fe9e83c;
  address brokerLiquidator = 0xeAe8EaB31E7299Cc4c7C6F08f3C1AA8eF08dC175;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    address operator = deployer;
    address pauser = deployer;
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    MarketFactory impl = new MarketFactory(
      moolah,
      liquidator,
      publicLiquidator,
      listaRevenueDistributor,
      buyback,
      autoBuyback,
      WBNB,
      slisBNB,
      BNBProvider,
      slisBNBProvider,
      rateCalculator,
      brokerLiquidator
    );
    console.log("Implementation: ", address(impl));

    // Deploy proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, operator, pauser)
    );
    console.log("Loop WBNB Vault BNBProvider proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

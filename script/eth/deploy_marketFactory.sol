pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarketFactory } from "../../src/moolah/MarketFactory.sol";

contract MarketFactoryDeploy is DeployBase {
  // ETH mainnet addresses
  // Deploy order: ListaRevenueDistributor → MarketFactory → configure LendingFeeRecipient.setMarketFeeRecipient()
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70; // ETH Moolah Core
  address liquidator = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C; // ETH Liquidator
  address publicLiquidator = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5; // ETH PublicLiquidator
  address listaRevenueDistributor = address(0); // TODO: deploy ListaRevenueDistributor first, then fill address here
  address buyback = address(0); // not used on ETH, no buyback mechanism
  address autoBuyback = address(0); // not used on ETH, no auto buyback mechanism
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH on ETH (corresponds to WBNB on BSC)
  address sliBNB = address(0); // not used on ETH
  address ETHProvider = 0xFe34BF713F3C2499026cdFA5af43eb22AA2d1aDb; // ETHProvider (corresponds to BNBProvider on BSC)
  address slisBNBProvider = address(0); // not used on ETH
  address rateCalculator = address(0); // not needed initially, can be set later via setRateCalculator()
  address brokerLiquidator = address(0); // not needed initially, can be set later via setBrokerLiquidator()

  address operator = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // Manager Safe
  address pauser = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // Manager Safe

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    // NOTE: rateCalculator and brokerLiquidator are storage variables,
    // set via setRateCalculator() and setBrokerLiquidator() when needed
    MarketFactory impl = new MarketFactory(
      moolah,
      liquidator,
      publicLiquidator,
      listaRevenueDistributor,
      buyback,
      autoBuyback,
      WETH, // on BSC: WBNB
      sliBNB, // on ETH: address(0)
      ETHProvider, // on BSC: BNBProvider
      slisBNBProvider // on ETH: address(0)
    );
    console.log("MarketFactory implementation: ", address(impl));

    // Deploy proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, operator, pauser)
    );
    console.log("MarketFactory proxy: ", address(proxy));

    // Note: rateCalculator and brokerLiquidator are storage variables (not immutable).
    // Constructor writes to implementation storage, NOT proxy storage.
    // After deployment, call MarketFactory(proxy).setRateCalculator(addr) and
    // MarketFactory(proxy).setBrokerLiquidator(addr) when broker infra is ready.
    // On ETH these are address(0) initially — no action needed until fixed-term markets are introduced.

    vm.stopBroadcast();
  }
}

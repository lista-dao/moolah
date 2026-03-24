pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarketFactory } from "../src/moolah/MarketFactory.sol";

contract MarketFactoryDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address liquidator = 0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a;
  address publicLiquidator = 0x882475d622c687b079f149B69a15683FCbeCC6D9;
  address listaRevenueDistributor = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address buyback = 0x3b99A4177E3f430590A8473f353dD87a5a2e1BfC;
  address autoBuyback = 0xFfd3a57E8DB4f51FA01c72F06Ff30BDFDa9908e6;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address BNBProvider = 0x367384C54756a25340c63057D87eA22d47Fd5701;
  address slisBNBProvider = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;
  address rateCalculator = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address operator = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
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

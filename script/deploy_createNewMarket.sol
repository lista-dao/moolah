pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  // todo update moolah irm liquidator oracleAdapter
  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv965 = 965 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);
    // collateral-slisBNB loan-WBNB lltv-96.5%
    params[0] = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv965
    });
    // collateral-ETH loan-WBNB lltv-80%
    params[1] = MarketParams({ loanToken: WBNB, collateralToken: ETH, oracle: multiOracle, irm: irm, lltv: lltv80 });
    // collateral-slisBNB loan-USD1 lltv-70%
    params[2] = MarketParams({
      loanToken: USD1,
      collateralToken: slisBNB,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv70
    });
    // collateral-ETH loan-USD1 lltv-70%
    params[3] = MarketParams({ loanToken: USD1, collateralToken: ETH, oracle: multiOracle, irm: irm, lltv: lltv70 });

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < 4; i++) {
      // create market
      moolah.createMarket(params[i]);
    }

    vm.stopBroadcast();
  }
}

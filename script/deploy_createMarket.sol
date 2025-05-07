pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address ptClisBNB30Otc = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;
  uint256 lltv965 = 965 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);
    // collateral-BTCB loan-USDT lltv-80%
    params[0] = MarketParams({
      loanToken: USDT,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ETH loan-USDT lltv-80%
    params[1] = MarketParams({
      loanToken: USDT,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-WBNB loan-USDT lltv-80%
    params[2] = MarketParams({
      loanToken: USDT,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-slisBNB loan-USDT lltv-80%
    params[3] = MarketParams({
      loanToken: USDT,
      collateralToken: slisBNB,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < 4; i++) {
      // create market
      moolah.createMarket(params[i]);
    }

    vm.stopBroadcast();
  }
}

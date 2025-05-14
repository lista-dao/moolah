pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateWBNBMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address asBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address ptClisBNB = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
  address USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv85 = 85 * 1e16;
  uint256 lltv915 = 915 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams slisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams asBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: asBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams BTCBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams ptClisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB,
      oracle: ptOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams USDTParams = MarketParams({
      loanToken: WBNB,
      collateralToken: USDTParams,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    vm.startBroadcast(deployerPrivateKey);
    moolah.createMarket(slisBNBParams);
    moolah.createMarket(asBNBParams);
    moolah.createMarket(BTCBParams);
    moolah.createMarket(solvBTCParams);
    moolah.createMarket(ptClisBNBParams);
    moolah.createMarket(USDTParams);
    vm.stopBroadcast();
  }
}

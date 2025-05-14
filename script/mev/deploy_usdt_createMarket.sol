pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateUSDTMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
  address ptSUSDe = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv85 = 85 * 1e16;
  uint256 lltv915 = 915 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams BTCBParams = MarketParams({
      loanToken: USDT,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams solvBTCParams = MarketParams({
      loanToken: USDT,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams USDeParams = MarketParams({
      loanToken: USDT,
      collateralToken: USDe,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams ptSUSDeParams = MarketParams({
      loanToken: USDT,
      collateralToken: ptSUSDe,
      oracle: ptOracle,
      irm: irm,
      lltv: lltv915
    });

    vm.startBroadcast(deployerPrivateKey);
    moolah.createMarket(BTCBParams);
    moolah.createMarket(solvBTCParams);
    moolah.createMarket(USDeParams);
    moolah.createMarket(ptSUSDeParams);
    vm.stopBroadcast();
  }
}

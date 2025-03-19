pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  // todo
  Moolah moolah = Moolah(0x61E1a5D17F01A4ed4788e9B1Ca4110C2925f8975);
  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address BTCB = 0x4BB2f2AA54c6663BFFD37b54eCd88eD81bC8B3ec;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address ptClisBNB25apr = 0x0A9498fb5B811E1AC4369bcdce427f7a3D2816eB;
  address solvBTC = 0xB1E63330f4718772CF939128d222389b30C70cF2;

  address multiOracle = 0x002d038Ada9BEF58e23587348cBcd75075514FD2;

  address bot = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address liquidator = 0x65c559d41904a43cCf7bd9BF7B5B34896a39EBea;
  address irm = 0x803da834B2Ff96D9055F1057dd8907AD776bEAA1;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);
    // collateral-BTCB loan-WBNB lltv-80%
    params[0] = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-slisBNB loan-WBNB lltv-80%
    params[1] = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ptClisBNB25apr loan-WBNB lltv-90%
    params[2] = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv90
    });
    // collateral-solvBTC loan-WBNB lltv-70%
    params[3] = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);
    // enable lltv
    moolah.enableLltv(lltv70);
    moolah.enableLltv(lltv80);
    moolah.enableLltv(lltv90);

    for (uint256 i = 0; i < 4; i++) {
      // create market
      moolah.createMarket(params[i]);

      // set fee
      Id id = params[i].id();

      // add liquidation whitelist
      moolah.addLiquidationWhitelist(id, bot);
      moolah.addLiquidationWhitelist(id, liquidator);
    }

    vm.stopBroadcast();
  }
}

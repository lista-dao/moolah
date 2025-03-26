pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  // todo
  Moolah moolah = Moolah(0xb1732a5BE3812e0095de327df9DbF5044C2Fe9a2);
  address BTCB = 0x4BB2f2AA54c6663BFFD37b54eCd88eD81bC8B3ec;
  address ETH = 0xE7bCB9e341D546b66a46298f4893f5650a56e99E;
  address wBETH = 0x34f8f72e3f14Ede08bbdA1A19a90B35a80f3E789;
  address wstETH = 0x41e3750FafC565f89c11DF06fEE257b93bB19A31;
  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address ptClisBNB25apr = 0x0A9498fb5B811E1AC4369bcdce427f7a3D2816eB;
  address asUSDF = 0xb77380b3d7E384Aa05477A7eEAEd4db3420216f1;
  address solvBTC = 0xB1E63330f4718772CF939128d222389b30C70cF2;
  address Stone = 0xb982479692b9f9D5d6582a36f49255205b18aE9e;

  address USDT = 0x49b1401B4406Fe0B32481613bF1bC9Fe4B9378aC;
  address lisUSD = 0x785b5d1Bde70bD6042877cA08E4c73e0a40071af;
  address USDC = 0xA528b0E61b72A0191515944cD8818a88d1D1D22b;
  address multiOracle = 0x002d038Ada9BEF58e23587348cBcd75075514FD2;

  address bot = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address liquidator = 0x44911A67bC66f539487F3A3c0502B00a642254e2;
  address irm = 0x0A9498fb5B811E1AC4369bcdce427f7a3D2816eB;
  uint256 lltv86 = 86 * 1e16;
  uint256 lltv915 = 915 * 1e15;
  uint256 lltv945 = 945 * 1e15;
  uint256 lltv965 = 965 * 1e15;

  uint256 fee = 5 * 1e16;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](60);
    // collateral-BTCB loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[0] = MarketParams({
      loanToken: USDT,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-BTCB loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[1] = MarketParams({
      loanToken: lisUSD,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-BTCB loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[2] = MarketParams({
      loanToken: USDC,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-ETH loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[3] = MarketParams({
      loanToken: USDT,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-ETH loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[4] = MarketParams({
      loanToken: lisUSD,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-ETH loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[5] = MarketParams({
      loanToken: USDC,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wBETH loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[6] = MarketParams({
      loanToken: USDT,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wBETH loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[7] = MarketParams({
      loanToken: lisUSD,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wBETH loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[8] = MarketParams({
      loanToken: USDC,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wstETH loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[9] = MarketParams({
      loanToken: USDT,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wstETH loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[10] = MarketParams({
      loanToken: lisUSD,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-wstETH loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[11] = MarketParams({
      loanToken: USDC,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-WBNB loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[12] = MarketParams({
      loanToken: USDT,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-WBNB loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[13] = MarketParams({
      loanToken: lisUSD,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-WBNB loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[14] = MarketParams({
      loanToken: USDC,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-slisBNB loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[15] = MarketParams({
      loanToken: USDT,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-slisBNB loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[16] = MarketParams({
      loanToken: lisUSD,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-slisBNB loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[17] = MarketParams({
      loanToken: USDC,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-BTCB loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[18] = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-ETH loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[19] = MarketParams({
      loanToken: WBNB,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wBETH loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[20] = MarketParams({
      loanToken: WBNB,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wstETH loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[21] = MarketParams({
      loanToken: WBNB,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-slisBNB loan-WBNB lltv-94.5% fee-5% oracle-multiOracle
    params[22] = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv945
    });
    // collateral-pt-clisBNB-25apr loan-WBNB lltv-96.5% fee-5% oracle-multiOracle
    params[23] = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    // collateral-BTCB loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[24] = MarketParams({
      loanToken: slisBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-ETH loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[25] = MarketParams({
      loanToken: slisBNB,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wBETH loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[26] = MarketParams({
      loanToken: slisBNB,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wstETH loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[27] = MarketParams({
      loanToken: slisBNB,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-pt-clisBNB-25apr loan-slisBNB lltv-96.5% fee-5% oracle-multiOracle
    params[28] = MarketParams({
      loanToken: slisBNB,
      collateralToken: ptClisBNB25apr,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    // collateral-BTCB loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[29] = MarketParams({
      loanToken: ETH,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wBETH loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[30] = MarketParams({
      loanToken: ETH,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-WBNB loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[31] = MarketParams({
      loanToken: ETH,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-slisBNB loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[32] = MarketParams({
      loanToken: ETH,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wstETH loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[33] = MarketParams({
      loanToken: ETH,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-ETH loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[34] = MarketParams({
      loanToken: BTCB,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wBETH loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[35] = MarketParams({
      loanToken: BTCB,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-WBNB loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[36] = MarketParams({
      loanToken: BTCB,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-slisBNB loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[37] = MarketParams({
      loanToken: BTCB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-wstETH loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[38] = MarketParams({
      loanToken: BTCB,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-asUSDF loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[39] = MarketParams({
      loanToken: USDT,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-asUSDF loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[40] = MarketParams({
      loanToken: lisUSD,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-asUSDF loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[41] = MarketParams({
      loanToken: USDC,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-asUSDF loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[42] = MarketParams({
      loanToken: WBNB,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-asUSDF loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[43] = MarketParams({
      loanToken: slisBNB,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-asUSDF loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[44] = MarketParams({
      loanToken: BTCB,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-asUSDF loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[45] = MarketParams({
      loanToken: ETH,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-solvBTC loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[46] = MarketParams({
      loanToken: USDT,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-solvBTC loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[47] = MarketParams({
      loanToken: lisUSD,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-solvBTC loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[48] = MarketParams({
      loanToken: USDC,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-solvBTC loan-ETH lltv-91.5% fee-5% oracle-multiOracle
    params[49] = MarketParams({
      loanToken: ETH,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-solvBTC loan-BTCB lltv-94.5% fee-5% oracle-multiOracle
    params[50] = MarketParams({
      loanToken: BTCB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv945
    });
    // collateral-solvBTC loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[51] = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-solvBTC loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[52] = MarketParams({
      loanToken: slisBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-Stone loan-USDT lltv-86% fee-5% oracle-multiOracle
    params[53] = MarketParams({
      loanToken: USDT,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-Stone loan-lisUSD lltv-86% fee-5% oracle-multiOracle
    params[54] = MarketParams({
      loanToken: lisUSD,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-Stone loan-USDC lltv-86% fee-5% oracle-multiOracle
    params[55] = MarketParams({
      loanToken: USDC,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    // collateral-Stone loan-ETH lltv-94.5% fee-5% oracle-multiOracle
    params[56] = MarketParams({
      loanToken: ETH,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv945
    });
    // collateral-Stone loan-BTCB lltv-91.5% fee-5% oracle-multiOracle
    params[57] = MarketParams({
      loanToken: BTCB,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-Stone loan-WBNB lltv-91.5% fee-5% oracle-multiOracle
    params[58] = MarketParams({
      loanToken: WBNB,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });
    // collateral-Stone  loan-slisBNB lltv-91.5% fee-5% oracle-multiOracle
    params[59] = MarketParams({
      loanToken: slisBNB,
      collateralToken: Stone,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    vm.startBroadcast(deployerPrivateKey);
    // enable lltv
    moolah.enableLltv(lltv86);
    moolah.enableLltv(lltv915);
    moolah.enableLltv(lltv945);
    moolah.enableLltv(lltv965);

    for (uint256 i = 0; i < 60; i++) {
      // create market
      moolah.createMarket(params[i]);

      // set fee
      moolah.setFee(params[i], fee);
      Id id = params[i].id();

      // add liquidation whitelist
      moolah.addLiquidationWhitelist(id, bot);
      moolah.addLiquidationWhitelist(id, liquidator);
    }

    vm.stopBroadcast();
  }
}

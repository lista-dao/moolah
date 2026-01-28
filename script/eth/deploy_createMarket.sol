pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70);
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address PTUSDe27NOV2025 = 0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7;
  address cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
  address ETH_wstETH = 0xDB8aAB8a0b28F3ceAaC07E749559C45fAc8B775c;
  address USDT_USDC = 0x0c1BFFa53Cf93220381D88C8FA1bf823a932Aa23;
  address USDT_USD1 = 0x986325959E84a46361D4A4CF18b9e95F2206405B;
  address WBTC_cbBTC = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22;
  address USDT_USDe = 0xCC28Aa85f146F28Fc3F47B28334BE3Cc3646EA16;
  address USDC_USDe = 0xE830a2F63eeE5d3cEaDEda0C138cc176B037dae8;

  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address PTUSDe27NOV2025USD1Oracle = 0xb169d2459F51d02d7fC8A39498ec2801652b594c;
  address ETH_wstETHSmartProvider = 0x92729237Ce941142c686f908136bFA93E9aC935c;
  address USDT_USDCSmartProvider = 0x50dce7e3b24510Ec6eC2F7ad3b2035aa32861aeC;
  address USDT_USD1SmartProvider = 0x61864d70C652D7a6a4fc4Fc5aFb6b7FebDC4B194;
  address WBTC_cbBTCSmartProvider = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;
  address USDT_USDeSmartProvider = 0xDfdB56a9e2F68c74Fca76c95E852D920890b36D4;
  address USDC_USDeSmartProvider = 0x6Ae702D18B0fCff0deB7273d4453E9AF67EC153B;

  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  address fixedRateIRM = 0x9A7cA2CfB886132B6024789163e770979E4222e1;

  uint256 lltv86 = 0.86 ether;
  uint256 lltv915 = 0.915 ether;
  uint256 lltv945 = 0.945 ether;
  uint256 lltv965 = 0.965 ether;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](6);
    params[0] = MarketParams({
      loanToken: USD1,
      collateralToken: ETH_wstETH,
      oracle: ETH_wstETHSmartProvider,
      irm: irm,
      lltv: lltv86
    });
    params[1] = MarketParams({
      loanToken: USD1,
      collateralToken: USDT_USDC,
      oracle: USDT_USDCSmartProvider,
      irm: irm,
      lltv: lltv86
    });
    params[2] = MarketParams({
      loanToken: USD1,
      collateralToken: USDT_USD1,
      oracle: USDT_USD1SmartProvider,
      irm: irm,
      lltv: lltv965
    });
    params[3] = MarketParams({
      loanToken: USD1,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv965
    });
    params[4] = MarketParams({
      loanToken: USD1,
      collateralToken: USDT_USDe,
      oracle: USDT_USDeSmartProvider,
      irm: irm,
      lltv: lltv945
    });
    params[5] = MarketParams({
      loanToken: USD1,
      collateralToken: USDC_USDe,
      oracle: USDC_USDeSmartProvider,
      irm: irm,
      lltv: lltv945
    });

    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < 6; i++) {
      Id id = params[i].id();
      console.log("market id:");
      console.logBytes32(Id.unwrap(id));
      // check if market already exists
      (, , , , uint128 lastUpdate, ) = moolah.market(id);
      if (lastUpdate != 0) {
        console.log("market already exists");
        continue;
      }
      // create market
      moolah.createMarket(params[i]);
      console.log("market created");
    }
    vm.stopBroadcast();
  }
}

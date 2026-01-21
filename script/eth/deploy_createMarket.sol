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

  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address PTUSDe27NOV2025USD1Oracle = 0xb169d2459F51d02d7fC8A39498ec2801652b594c;

  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  address fixedRateIRM = 0x9A7cA2CfB886132B6024789163e770979E4222e1;

  uint256 lltv86 = 0.86 ether;
  uint256 lltv915 = 0.915 ether;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](1);
    params[0] = MarketParams({ loanToken: USD1, collateralToken: USDT, oracle: multiOracle, irm: irm, lltv: lltv915 });

    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < 1; i++) {
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

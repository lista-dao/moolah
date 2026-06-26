pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

/// @notice Step 2: Create 4 new markets for ETH Phase 2
///   Market #1: loan=WETH, collateral=wstETH,          oracle=ResilientOracle, lltv=96.5%
///   Market #2: loan=WETH, collateral=wbETH,           oracle=ResilientOracle, lltv=96.5%
///   Market #5: loan=USDT, collateral=WBTC_cbBTC_LP,   oracle=SmartProvider,   lltv=80%
///   Market #6: loan=USDC, collateral=WBTC_cbBTC_LP,   oracle=SmartProvider,   lltv=80%
contract CreateMarketPhase2Deploy is DeployBase {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70);

  // Tokens
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address WBTC_cbBTC = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22; // StableSwapLPCollateral

  // Oracles
  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301; // ResilientOracle
  address WBTC_cbBTCSmartProvider = 0x893666d84B374f96Ab500f56728283eeBB94A9ac; // SmartProvider

  // IRM
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;

  // LLTV
  uint256 lltv965 = 0.965 ether; // 96.5% for wstETH, wbETH
  uint256 lltv80 = 0.80 ether; // 80% for WBTC/cbBTC LP

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);

    // Market #1: wstETH → WETH, 96.5%
    // Oracle: ResilientOracle (wstETH uses stEthPerToken exchange rate, monotonically increasing)
    params[0] = MarketParams({
      loanToken: WETH,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });

    // Market #2: wbETH → WETH, 96.5%
    // Oracle: ResilientOracle (wbETH uses exchangeRate, monotonically increasing)
    params[1] = MarketParams({ loanToken: WETH, collateralToken: wBETH, oracle: multiOracle, irm: irm, lltv: lltv965 });

    // Market #5: WBTC/cbBTC LP → USDT, 80%
    // Oracle: SmartProvider (minPrice(WBTC, cbBTC) * virtualPrice)
    params[2] = MarketParams({
      loanToken: USDT,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });

    // Market #6: WBTC/cbBTC LP → USDC, 80%
    // Oracle: SmartProvider (minPrice(WBTC, cbBTC) * virtualPrice)
    params[3] = MarketParams({
      loanToken: USDC,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < params.length; i++) {
      Id id = params[i].id();
      console.log("market id:");
      console.logBytes32(Id.unwrap(id));

      // check if market already exists
      (, , , , uint128 lastUpdate, ) = moolah.market(id);
      if (lastUpdate != 0) {
        console.log("market already exists, skip");
        continue;
      }

      moolah.createMarket(params[i]);
      console.log("market created");
    }

    vm.stopBroadcast();
  }
}

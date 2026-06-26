pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { Moolah } from "moolah/Moolah.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

/// @notice Step 5: Set liquidation whitelist for 4 new markets
///   Part A: Moolah contract — batchToggleLiquidationWhitelist
///   Part B: Liquidator contract — batchSetMarketWhitelist + setTokenWhitelist
///   Part C: Liquidator & PublicLiquidator — batchSetSmartProviders (for SmartLP markets)
contract LiquidationWhitelistPhase2Deploy is DeployBase {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70);
  Liquidator liquidatorContract = Liquidator(payable(0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C));
  PublicLiquidator publicLiquidatorContract = PublicLiquidator(payable(0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5));

  address liquidatorAddr = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
  address publicLiquidatorAddr = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;

  // Tokens
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address WBTC_cbBTC = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22;

  // Oracles / SmartProvider
  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address WBTC_cbBTCSmartProvider = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;

  // IRM
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;

  // LLTV
  uint256 lltv965 = 0.965 ether;
  uint256 lltv80 = 0.80 ether;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    // Build market params to compute IDs
    MarketParams[4] memory params;
    params[0] = MarketParams({
      loanToken: WETH,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    params[1] = MarketParams({ loanToken: WETH, collateralToken: wBETH, oracle: multiOracle, irm: irm, lltv: lltv965 });
    params[2] = MarketParams({
      loanToken: USDT,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });
    params[3] = MarketParams({
      loanToken: USDC,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });

    Id[] memory ids = new Id[](4);
    bytes32[] memory idBytes = new bytes32[](4);
    for (uint256 i = 0; i < 4; i++) {
      ids[i] = MarketParamsLib.id(params[i]);
      idBytes[i] = Id.unwrap(ids[i]);
      console.log("market id:");
      console.logBytes32(idBytes[i]);
    }

    // --- Part A: Moolah contract whitelist ---
    address[][] memory accountInfo = new address[][](4);
    address[] memory liquidators = new address[](3);
    liquidators[0] = liquidatorAddr;
    liquidators[1] = bot;
    liquidators[2] = publicLiquidatorAddr;

    for (uint256 i = 0; i < 4; i++) {
      accountInfo[i] = liquidators;
    }

    vm.startBroadcast(deployerPrivateKey);

    // Part A: Moolah — allow these accounts to liquidate in these markets
    moolah.batchToggleLiquidationWhitelist(ids, accountInfo, true);
    console.log("Part A done: Moolah liquidation whitelist set");

    // --- Part B: Liquidator contract — market + token whitelist ---
    // Filter out already-whitelisted market IDs to avoid WhitelistSameStatus revert
    uint256 newCount = 0;
    for (uint256 i = 0; i < idBytes.length; i++) {
      if (!liquidatorContract.marketWhitelist(idBytes[i])) newCount++;
    }
    if (newCount > 0) {
      bytes32[] memory newIdBytes = new bytes32[](newCount);
      uint256 idx = 0;
      for (uint256 i = 0; i < idBytes.length; i++) {
        if (!liquidatorContract.marketWhitelist(idBytes[i])) {
          newIdBytes[idx++] = idBytes[i];
        }
      }
      liquidatorContract.batchSetMarketWhitelist(newIdBytes, true);
      console.log("Part B done: Liquidator market whitelist set (%d new)", newCount);
    } else {
      console.log("Part B skipped: all markets already whitelisted");
    }

    // WBTC_cbBTC LP token (collateral for market #5 & #6) — needs whitelist on Liquidator
    if (!liquidatorContract.tokenWhitelist(WBTC_cbBTC)) {
      liquidatorContract.setTokenWhitelist(WBTC_cbBTC, true);
      console.log("Part B done: Liquidator token whitelist set for WBTC_cbBTC LP");
    } else {
      console.log("Part B skipped: WBTC_cbBTC LP token already whitelisted");
    }

    // --- Part C: SmartProvider whitelist on Liquidator & PublicLiquidator ---
    // Required for SmartLP collateral redemption during liquidation
    // batchSetSmartProviders is idempotent (no revert if already set), but skip for cleanliness
    address[] memory smartProviders = new address[](1);
    smartProviders[0] = WBTC_cbBTCSmartProvider;

    if (!liquidatorContract.smartProviders(WBTC_cbBTCSmartProvider)) {
      liquidatorContract.batchSetSmartProviders(smartProviders, true);
      console.log("Part C done: Liquidator SmartProvider whitelist set");
    } else {
      console.log("Part C skipped: Liquidator SmartProvider already whitelisted");
    }

    if (!publicLiquidatorContract.smartProviders(WBTC_cbBTCSmartProvider)) {
      publicLiquidatorContract.batchSetSmartProviders(smartProviders, true);
      console.log("Part C done: PublicLiquidator SmartProvider whitelist set");
    } else {
      console.log("Part C skipped: PublicLiquidator SmartProvider already whitelisted");
    }

    vm.stopBroadcast();

    console.log("All liquidation config done!");
  }
}

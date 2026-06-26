pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

/// @notice Step 7: Update existing USDT/USDC vaults — add WBTC/cbBTC LP markets (#5 & #6)
///   USDT/USDC vault roles have been transferred to TimeLock.
///   This script ONLY generates calldata for TimeLock multisig proposals.
///   It does NOT broadcast any transactions.
///
///   Required TimeLock operations per vault:
///     1. setCap — set cap for the new WBTC/cbBTC LP market
///     2. setSupplyQueue — append the new market to existing supply queue
///
///   NOTE: Each vault currently has 2 markets in supply queue:
///     - USDT vault: [USDT/USDT_USDC_LP/lltv96.5%, USDT/WETH/lltv86%]
///     - USDC vault: [USDC/USDT_USDC_LP/lltv96.5%, USDC/WETH/lltv86%]
///   The new WBTC/cbBTC LP market is appended as the 3rd element.
contract VaultConfigUsdtUsdcPhase2Deploy is DeployBase {
  using MarketParamsLib for MarketParams;

  MoolahVault usdtVault = MoolahVault(0x28643FFD79256719D6AcbCF25Cb44576cAeBCf12);
  MoolahVault usdcVault = MoolahVault(0x9651Ae50a5763c6f9B883f9d50e8116281CFcab2);

  // Tokens
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address WBTC_cbBTC = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22;
  address USDT_USDC = 0x0c1BFFa53Cf93220381D88C8FA1bf823a932Aa23;

  // Oracle — SmartProvider for WBTC/cbBTC LP
  address WBTC_cbBTCSmartProvider = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;
  address USDT_USDCSmartProvider = 0x50dce7e3b24510Ec6eC2F7ad3b2035aa32861aeC;

  // IRM
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;

  // LLTV
  uint256 lltv80 = 0.80 ether;
  uint256 lltv86 = 0.86 ether;
  uint256 lltv965 = 0.965 ether;

  // Cap: $20M in 6-decimal units (USDT/USDC)
  uint256 cap = 20_000_000e6;

  function run() public view {
    // Market #5: WBTC/cbBTC LP → USDT
    MarketParams memory usdtNewMarket = MarketParams({
      loanToken: USDT,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });

    // Market #6: WBTC/cbBTC LP → USDC
    MarketParams memory usdcNewMarket = MarketParams({
      loanToken: USDC,
      collateralToken: WBTC_cbBTC,
      oracle: WBTC_cbBTCSmartProvider,
      irm: irm,
      lltv: lltv80
    });

    // Existing market #1 in USDT vault (collateral=USDT_USDC LP, lltv=96.5%) — supplyQueue[0]
    MarketParams memory usdtExistingMarket0 = MarketParams({
      loanToken: USDT,
      collateralToken: USDT_USDC,
      oracle: USDT_USDCSmartProvider,
      irm: irm,
      lltv: lltv965
    });

    // Existing market #2 in USDT vault (collateral=WETH, lltv=86%) — supplyQueue[1]
    MarketParams memory usdtExistingMarket1 = MarketParams({
      loanToken: USDT,
      collateralToken: WETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });

    // Existing market #1 in USDC vault (collateral=USDT_USDC LP, lltv=96.5%) — supplyQueue[0]
    MarketParams memory usdcExistingMarket0 = MarketParams({
      loanToken: USDC,
      collateralToken: USDT_USDC,
      oracle: USDT_USDCSmartProvider,
      irm: irm,
      lltv: lltv965
    });

    // Existing market #2 in USDC vault (collateral=WETH, lltv=86%) — supplyQueue[1]
    MarketParams memory usdcExistingMarket1 = MarketParams({
      loanToken: USDC,
      collateralToken: WETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });

    console.log("========================================");
    console.log("TimeLock Calldata for USDT Vault (0x28643FFD79256719D6AcbCF25Cb44576cAeBCf12)");
    console.log("========================================");

    // 1. setCap calldata
    console.log("--- setCap calldata ---");
    console.logBytes(abi.encodeWithSelector(MoolahVault.setCap.selector, usdtNewMarket, cap));

    // 2. setSupplyQueue calldata (2 existing + 1 new)
    Id[] memory usdtQueue = new Id[](3);
    usdtQueue[0] = usdtExistingMarket0.id(); // existing USDT_USDC LP market
    usdtQueue[1] = usdtExistingMarket1.id(); // existing WETH market
    usdtQueue[2] = usdtNewMarket.id(); // new WBTC/cbBTC LP market
    console.log("--- setSupplyQueue calldata ---");
    console.logBytes(abi.encodeWithSelector(MoolahVault.setSupplyQueue.selector, usdtQueue));

    console.log("========================================");
    console.log("TimeLock Calldata for USDC Vault (0x9651Ae50a5763c6f9B883f9d50e8116281CFcab2)");
    console.log("========================================");

    // 1. setCap calldata
    console.log("--- setCap calldata ---");
    console.logBytes(abi.encodeWithSelector(MoolahVault.setCap.selector, usdcNewMarket, cap));

    // 2. setSupplyQueue calldata (2 existing + 1 new)
    Id[] memory usdcQueue = new Id[](3);
    usdcQueue[0] = usdcExistingMarket0.id(); // existing USDT_USDC LP market
    usdcQueue[1] = usdcExistingMarket1.id(); // existing WETH market
    usdcQueue[2] = usdcNewMarket.id(); // new WBTC/cbBTC LP market
    console.log("--- setSupplyQueue calldata ---");
    console.logBytes(abi.encodeWithSelector(MoolahVault.setSupplyQueue.selector, usdcQueue));

    console.log("========================================");
    console.log("Done! Submit above calldata to TimeLock multisig.");
  }
}

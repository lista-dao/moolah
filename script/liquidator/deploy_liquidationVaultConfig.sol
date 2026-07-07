pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { BrokerLiquidator } from "liquidator/BrokerLiquidator.sol";

/// @dev Configures the LiquidationVault and wires the two live liquidators onto the shared fund pool.
///
/// Ordering hard-constraint: register the liquidator in the vault (setLiquidator) BEFORE pointing the
/// liquidator at the vault (setFundSource) — setFundSource reverts unless the vault already lists it.
/// Reserve migration (vault.collectERC20 / collectETH) must run AFTER setFundSource, since the pull is
/// on-demand and consumes local balance first. Recommended: execute atomically via multisig.
///
/// Fill in the deployed addresses before running.
contract LiquidationVaultConfigDeploy is DeployBase {
  LiquidationVault vault = LiquidationVault(payable(address(0)));
  Liquidator liquidator = Liquidator(payable(address(0)));
  BrokerLiquidator brokerLiquidator = BrokerLiquidator(payable(address(0)));

  // ResilientOracle used by the sell loss guard (peek() -> 8-decimal USD).
  address resilientOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750; // multiOracle (mainnet)
  // Optional revenue collector (0 to skip wiring here).
  address revenueCollector = address(0);

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  // Sell whitelist — copy the live Liquidator whitelist set.
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address pair = 0x111111125421cA6dc452d289314280a0f8842A65; // 1inch aggregation router

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // 1) Oracle + sell whitelist (token + pair). BNB_ADDRESS must be whitelisted for sellBNB/collectETH.
    vault.setOracle(resilientOracle);
    vault.setTokenWhitelist(BNB_ADDRESS, true);
    vault.setTokenWhitelist(WBNB, true);
    vault.setTokenWhitelist(BTCB, true);
    vault.setTokenWhitelist(slisBNB, true);
    vault.setTokenWhitelist(solvBTC, true);
    vault.setPairWhitelist(pair, true);

    // maxSwapLossBp (50_000 = 5%) and maxDailyLossUsd (1000e8) are set in initialize(); override here if needed.

    // 2) Register liquidators in the vault (required before each liquidator's setFundSource).
    vault.setLiquidator(address(liquidator), true);
    vault.setLiquidator(address(brokerLiquidator), true);

    // 3) Point each liquidator at the vault (grey-scale cut-over; 0 rolls back to legacy behavior).
    liquidator.setFundSource(address(vault));
    brokerLiquidator.setFundSource(address(vault));

    // 4) Optional: authorize the RevenueCollector to pull fees via withdraw*. The collector side must
    //    also call RevenueCollector.updateLiquidator(vault, true) from its own MANAGER.
    if (revenueCollector != address(0)) {
      vault.setRevenueCollector(revenueCollector);
    }

    vm.stopBroadcast();

    console.log("LiquidationVault config + wiring done!");
  }
}

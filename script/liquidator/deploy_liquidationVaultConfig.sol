pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";

/// @dev Step 2 of rollout — VAULT-SIDE config only, run by the deployer while it still holds the fresh
///      vault's MANAGER role (i.e. BEFORE the role-transfer script). It performs NO action on the live
///      Liquidator/BrokerLiquidator, so it cannot revert on their multisig-held MANAGER.
///
///      setFundSource on the live liquidators + reserve migration (collect*) are a SEPARATE, multisig-
///      executed step — see deploy_liquidationVaultWire.sol. Role handover — see
///      deploy_liquidationVaultTransferRole.sol.
///
/// IMPORTANT: the sell/collect whitelist MUST include every whitelisted market's LOAN token as
/// well as its collateral — the vault's job is to sell seized collateral INTO the loan token and to
/// refill the pool via provideFund. Verify each address below against the live market params before
/// running; token labels differ across registries.
contract LiquidationVaultConfigDeploy is DeployBase {
  // ---- fill the freshly-deployed vault; guarded so a half-config run reverts ----
  LiquidationVault vault = LiquidationVault(payable(address(0)));

  // ResilientOracle used by the sell loss guard (peek() -> 8-decimal USD).
  address resilientOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750; // ResilientOracle (mainnet)
  // Optional revenue collector (0 to skip). NOTE: enabling it also requires the collector side to
  // call RevenueCollector.updateLiquidator(vault, true), and it grants the collector uncapped withdraw*
  // pull authority over the whole vault — decide deliberately.
  address revenueCollector = address(0);

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  // Pair/router used for sells (1inch aggregation router).
  address pair = 0x111111125421cA6dc452d289314280a0f8842A65;

  /// @dev Every token any whitelisted market uses as LOAN or collateral, plus BNB_ADDRESS (for
  ///      sellBNB/collectETH). LOAN tokens (lisUSD/USDT/USD1/WBNB) are required, not optional.
  function _whitelistTokens() internal pure returns (address[] memory t) {
    t = new address[](8);
    t[0] = BNB_ADDRESS;
    t[1] = WBNB; // loan (WBNB markets) + collateral
    t[2] = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // lisUSD  (loan)
    t[3] = 0x55d398326f99059fF775485246999027B3197955; // USDT    (loan)
    t[4] = 0x68B9A9eA70f4391c016746BE240037E5d4f63807; // USD1    (loan)
    t[5] = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB    (collateral)
    t[6] = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // slisBNB (collateral)
    t[7] = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7; // solvBTC (collateral)
  }

  function run() public {
    require(address(vault) != address(0), "set vault");
    require(resilientOracle != address(0) && pair != address(0), "set oracle/pair");

    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer: ", vm.addr(deployerPrivateKey));
    address[] memory tokens = _whitelistTokens();

    vm.startBroadcast(deployerPrivateKey);

    vault.setOracle(resilientOracle);
    for (uint256 i = 0; i < tokens.length; i++) {
      require(tokens[i] != address(0), "zero token");
      if (!vault.tokenWhitelist(tokens[i])) vault.setTokenWhitelist(tokens[i], true);
    }
    vault.setPairWhitelist(pair, true);

    // maxSwapLossBp (5%) / maxDailyLossUsd ($1000) come from initialize(); set an appropriate
    // per-pool value here for mainnet via vault.setMaxDailyLossUsd(...) if desired.

    if (revenueCollector != address(0)) vault.setRevenueCollector(revenueCollector);

    vm.stopBroadcast();
    console.log("LiquidationVault vault-side config done. Next: transfer roles, then wire (multisig).");
  }
}

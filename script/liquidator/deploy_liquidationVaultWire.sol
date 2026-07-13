pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { BrokerLiquidator } from "liquidator/BrokerLiquidator.sol";

interface IERC20bal {
  function balanceOf(address) external view returns (uint256);
}

interface IRevenueCollector {
  function updateLiquidator(address liquidator, bool addLiquidator) external;
}

/// @dev Step 4 of rollout — the MULTISIG batch that cuts the live liquidators over to the vault and
///      migrates their reserves. Every call here touches an ALREADY-LIVE contract (Liquidator,
///      BrokerLiquidator, RevenueCollector) whose MANAGER is the 3/6 Safe, so these must be one atomic
///      Safe transaction (not a deployer broadcast). vault.setLiquidator is NOT here — it is a vault-side
///      op done earlier by the deployer in the config script. Ordering:
///        1. liq.setFundSource(vault)               [liquidator MANAGER]
///        2. liq.setReflowBlacklist(LP, true)       [liquidator MANAGER]
///        3. RevenueCollector.updateLiquidator(vault) [collector MANAGER]
///        4. vault.collectERC20/ETH(liq, ...)       [vault MANAGER/BOT] — migrate the live reserve
///      Reserve amounts are read from LIVE balances at execution time — never hardcoded,
///      because reflow may already have moved part of a balance into the vault.
contract LiquidationVaultWire is DeployBase {
  LiquidationVault vault = LiquidationVault(payable(address(0)));
  Liquidator liquidator = Liquidator(payable(0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a));
  BrokerLiquidator brokerLiquidator = BrokerLiquidator(payable(0x3AA647a1e902833b61E503DbBFbc58992daa4868));
  // RevenueCollector (DEX fee + liquidation profit). Registers the vault so it can pull fees via the
  // ILiquidator withdraw selectors the vault reuses. Must match the address set in the config script.
  IRevenueCollector revenueCollector = IRevenueCollector(0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C);

  /// @dev Loan tokens whose standing reserves should be migrated from the liquidators into the vault.
  function _loanTokens() internal pure returns (address[] memory t) {
    t = new address[](5);
    t[0] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
    t[1] = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // lisUSD
    t[2] = 0x55d398326f99059fF775485246999027B3197955; // USDT
    t[3] = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // USD1
    t[4] = 0xcE24439F2D9C6a2289F741120FE202248B666666; // U (United Stables)
  }

  function run() public {
    require(address(vault) != address(0), "set vault");
    uint256 pk = _deployerKey();
    address[] memory loans = _loanTokens();

    vm.startBroadcast(pk);

    // 1: point each liquidator at the vault. Vault-side setLiquidator was already done by the deployer
    //    in the config script (deployer held vault MANAGER); require it so setFundSource can't revert on
    //    the liquidators' `vault.liquidators(address(this))` guard.
    require(
      vault.liquidators(address(liquidator)) && vault.liquidators(address(brokerLiquidator)),
      "run config script first (setLiquidator)"
    );
    if (liquidator.fundSource() != address(vault)) liquidator.setFundSource(address(vault));
    if (brokerLiquidator.fundSource() != address(vault)) brokerLiquidator.setFundSource(address(vault));

    // 3: blacklist existing smart-LP collateral from reflow (MarketFactory only auto-blacklists NEW
    //    markets, and only on the Liquidator). A wrong-entry plain liquidate must not push un-sellable
    //    LP into the vault; it stays in the liquidator, recoverable via redeemSmartCollateral.
    _blacklistLP();

    // 4: register the vault on the RevenueCollector (reciprocal of vault.setRevenueCollector in the
    //    config script) so claimLiquidationFee(vault, ...) is accepted. Requires the multisig to hold
    //    the collector's MANAGER role.
    revenueCollector.updateLiquidator(address(vault), true);

    // 5: migrate live reserves (read at execution time).
    _migrate(address(liquidator), loans);
    _migrate(address(brokerLiquidator), loans);

    vm.stopBroadcast();
    console.log("LiquidationVault wired + LP blacklisted + collector registered + reserves migrated.");
  }

  /// @dev Existing StableSwapLPCollateral tokens (moolah markets snapshot 2026-07-10). The slisBNB/BNB
  ///      and USDC/USDT LPs are also used in broker markets, so blacklist those on BOTH liquidators.
  function _blacklistLP() internal {
    address[7] memory lp = [
      0x719f6445cdAC08B84611D0F19d733F57214bcfee, // slisBNB & BNB   (LIQ + BRK)
      0x23BC296d67619eA11C9a8B49B8C396B798AF3330, // USDC & USDT     (LIQ + BRK)
      0xbBD3e74E69e6BDDDA8e5AAdC1460611A8f7cd05a, // U & USDT        (LIQ)
      0x6f4d7532A402D76F552E1F047Ff7e23bFe1A9f03, // BTCB & solvBTC  (LIQ)
      0x627B5567458A76e6B6a6a6BBe3FcFF7f81821a58, // $U & USDT       (LIQ)
      0x6c7EbA17dDB5D0435FCFb9053BB3087c1d10beB3, // lisUSD & USDT   (LIQ)
      0x091e6Ed7794d74b73081D32cAb59fa47ff15418d // USD1 & USDT     (LIQ)
    ];
    for (uint256 i = 0; i < lp.length; i++) {
      if (!liquidator.reflowBlacklist(lp[i])) liquidator.setReflowBlacklist(lp[i], true);
    }
    // broker smart-LP markets exist only for slisBNB/BNB (lp[0]) and USDC/USDT (lp[1]).
    if (!brokerLiquidator.reflowBlacklist(lp[0])) brokerLiquidator.setReflowBlacklist(lp[0], true);
    if (!brokerLiquidator.reflowBlacklist(lp[1])) brokerLiquidator.setReflowBlacklist(lp[1], true);
  }

  function _migrate(address liq, address[] memory loans) internal {
    for (uint256 i = 0; i < loans.length; i++) {
      uint256 bal = IERC20bal(loans[i]).balanceOf(liq);
      if (bal > 0) vault.collectERC20(liq, loans[i], bal);
    }
    uint256 nativeBal = liq.balance;
    if (nativeBal > 0) vault.collectETH(liq, nativeBal);
  }
}

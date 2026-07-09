pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { BrokerLiquidator } from "liquidator/BrokerLiquidator.sol";

interface IERC20bal {
  function balanceOf(address) external view returns (uint256);
}

/// @dev Step 4 of rollout — the MULTISIG batch that cuts the live liquidators over to the vault and
///      migrates their reserves. On mainnet MANAGER is the 3/6 Safe, so these calls must be one atomic
///      Safe transaction (not a single deployer broadcast). Ordering is enforced:
///        1. vault.setLiquidator(liq, true)      [vault MANAGER]  — must precede setFundSource
///        2. liq.setFundSource(vault)            [liquidator MANAGER]
///        3. vault.collectERC20/ETH(liq, ...)    [vault MANAGER/BOT] — migrate the live reserve
///      Reserve amounts are read from LIVE balances at execution time — never hardcoded,
///      because reflow may already have moved part of a balance into the vault.
contract LiquidationVaultWire is DeployBase {
  LiquidationVault vault = LiquidationVault(payable(address(0)));
  Liquidator liquidator = Liquidator(payable(0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a));
  BrokerLiquidator brokerLiquidator = BrokerLiquidator(payable(0x3AA647a1e902833b61E503DbBFbc58992daa4868));

  /// @dev Loan tokens whose standing reserves should be migrated from the liquidators into the vault.
  function _loanTokens() internal pure returns (address[] memory t) {
    t = new address[](4);
    t[0] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
    t[1] = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // lisUSD
    t[2] = 0x55d398326f99059fF775485246999027B3197955; // USDT
    t[3] = 0x68B9A9eA70f4391c016746BE240037E5d4f63807; // USD1
  }

  function run() public {
    require(address(vault) != address(0), "set vault");
    uint256 pk = _deployerKey();
    address[] memory loans = _loanTokens();

    vm.startBroadcast(pk);

    // 1 + 2: register then point each liquidator at the vault.
    if (!vault.liquidators(address(liquidator))) vault.setLiquidator(address(liquidator), true);
    if (!vault.liquidators(address(brokerLiquidator))) vault.setLiquidator(address(brokerLiquidator), true);
    if (liquidator.fundSource() != address(vault)) liquidator.setFundSource(address(vault));
    if (brokerLiquidator.fundSource() != address(vault)) brokerLiquidator.setFundSource(address(vault));

    // 3: migrate live reserves (read at execution time).
    _migrate(address(liquidator), loans);
    _migrate(address(brokerLiquidator), loans);

    vm.stopBroadcast();
    console.log("LiquidationVault wired + reserves migrated.");
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

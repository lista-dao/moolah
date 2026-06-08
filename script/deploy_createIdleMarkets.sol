// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { DeployBase } from "./DeployBase.sol";
import { IMoolah, MarketParams, Market, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Creates the per-loan-asset idle markets on BSC mainnet (USD1 / U / USDT / USDC / WBNB).
///         Caller must hold the OPERATOR role on Moolah.
///         Pre-requisite: MANAGER multisig has already called enableIrm(0) + enableLltv(0).
///         Idempotent; existing markets are skipped.
contract DeployCreateIdleMarkets is DeployBase {
  using MarketParamsLib for MarketParams;

  IMoolah constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR");

  // Singletons deployed via deploy_idleMarket.sol.
  address constant IDLE_COLLATERAL = 0xB39d0107635686e6613dCd08018520C2fd763fA3;
  address constant IDLE_ORACLE = 0xc259Ee9CB561dFb5DcA010b29b57F12341fF8733;

  // Loan tokens for the first batch of idle markets (PRD §6.1).
  address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
  address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
  address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  function run() public {
    uint256 deployerKey = _deployerKey();
    address deployer = vm.addr(deployerKey);
    console.log("Deployer:", deployer);
    console.log("Chain id:", block.chainid);

    require(
      IAccessControl(address(MOOLAH)).hasRole(OPERATOR_ROLE, deployer),
      "deployer does not have OPERATOR role on Moolah"
    );
    require(MOOLAH.isIrmEnabled(address(0)), "Moolah.enableIrm(0) not done");
    require(MOOLAH.isLltvEnabled(0), "Moolah.enableLltv(0) not done");

    address[5] memory loanTokens = [USD1, U, USDT, USDC, WBNB];
    string[5] memory labels = ["USD1", "U", "USDT", "USDC", "WBNB"];

    vm.startBroadcast(deployerKey);
    for (uint256 i; i < loanTokens.length; ++i) {
      MarketParams memory p = MarketParams({
        loanToken: loanTokens[i],
        collateralToken: IDLE_COLLATERAL,
        oracle: IDLE_ORACLE,
        irm: address(0),
        lltv: 0
      });
      Id id = p.id();
      console.log("---");
      console.log("Loan:", labels[i]);
      console.log("Market id:");
      console.logBytes32(Id.unwrap(id));

      Market memory m = MOOLAH.market(id);
      if (m.lastUpdate != 0) {
        console.log("  already exists, skipping");
        continue;
      }
      MOOLAH.createMarket(p);
      console.log("  created");
    }
    vm.stopBroadcast();
  }
}

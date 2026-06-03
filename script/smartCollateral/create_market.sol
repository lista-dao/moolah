pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import "./SCAddress.sol";

// Compute the 8 market IDs once COLLATERAL_* / SMART_PROVIDER_* are filled in SCAddress.
// Production market creation is a MarketFactory.batchCreateMarkets multisig op (OPERATOR = 0x8d38…)
// with oracle = SmartProvider and liquidatorSmartProviders = true. Run read-only (no --broadcast):
//   forge script script/smartCollateral/create_market.sol --rpc-url bsc
contract CreateMarketDeploy is DeployBase {
  using MarketParamsLib for MarketParams;

  uint256 constant LLTV = 965 * 1e15; // 96.5%

  function run() public view {
    address[4] memory loans = [USDT, USD1, U, USDC];
    MarketParams[] memory params = new MarketParams[](8);

    for (uint256 i = 0; i < 4; i++) {
      params[i] = MarketParams({
        loanToken: loans[i],
        collateralToken: COLLATERAL_USD1_USDT,
        oracle: SMART_PROVIDER_USD1_USDT,
        irm: IRM,
        lltv: LLTV
      });
      params[i + 4] = MarketParams({
        loanToken: loans[i],
        collateralToken: COLLATERAL_LISUSD_USDT,
        oracle: SMART_PROVIDER_LISUSD_USDT,
        irm: IRM,
        lltv: LLTV
      });
    }

    for (uint256 i = 0; i < 8; i++) {
      console.log("market index: ", i);
      console.logBytes32(Id.unwrap(params[i].id()));
    }
  }
}

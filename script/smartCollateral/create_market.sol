pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import "./SCAddress.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(MOOLAH);

  uint256 lltv75 = 75 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv915 = 915 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);
    params[0] = MarketParams({
      loanToken: USD1,
      collateralToken: COLLATERAL_SLISBNB_BNB,
      oracle: SMART_PROVIDER_BNB_SLISBNB,
      irm: IRM,
      lltv: lltv75
    });
    params[1] = MarketParams({
      loanToken: WBNB,
      collateralToken: COLLATERAL_SLISBNB_BNB,
      oracle: SMART_PROVIDER_BNB_SLISBNB,
      irm: IRM,
      lltv: lltv915
    });
    params[2] = MarketParams({
      loanToken: USD1,
      collateralToken: COLLATERAL_SOLVBTC_BTCB,
      oracle: SMART_PROVIDER_BTCB_SOLVBTC,
      irm: IRM,
      lltv: lltv75
    });
    params[3] = MarketParams({
      loanToken: WBNB,
      collateralToken: COLLATERAL_SOLVBTC_BTCB,
      oracle: SMART_PROVIDER_BTCB_SOLVBTC,
      irm: IRM,
      lltv: lltv80
    });

    // create market
    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < 4; i++) {
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

pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import "./LisAsterAddress.sol";

// Step 4: create the Moolah market using the SmartLP as collateral.
//
//   loan       = Aster
//   collateral = lisAster & Aster SmartLP
//   oracle     = lisAster & Aster SmartProvider
//   irm        = IRM
//   lltv       = 91.5%
//
// Requires COLLATERAL_LISASTER_ASTER and SMART_PROVIDER_LISASTER_ASTER set in LisAsterAddress.sol.
//
// forge script script/smartCollateral/lisAster/4_create_market.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract CreateLisAsterAsterMarket is DeployBase {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(MOOLAH);

  uint256 lltv915 = 915 * 1e15; // 91.5%

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    require(COLLATERAL_LISASTER_ASTER != address(0), "set COLLATERAL_LISASTER_ASTER first");
    require(SMART_PROVIDER_LISASTER_ASTER != address(0), "set SMART_PROVIDER_LISASTER_ASTER first");

    MarketParams memory params = MarketParams({
      loanToken: ASTER,
      collateralToken: COLLATERAL_LISASTER_ASTER,
      oracle: SMART_PROVIDER_LISASTER_ASTER,
      irm: IRM,
      lltv: lltv915
    });

    Id id = params.id();
    console.log("market id:");
    console.logBytes32(Id.unwrap(id));

    vm.startBroadcast(deployerPrivateKey);

    (, , , , uint128 lastUpdate, ) = moolah.market(id);
    if (lastUpdate != 0) {
      console.log("market already exists");
    } else {
      moolah.createMarket(params);
      console.log("market created");
    }

    vm.stopBroadcast();
  }
}

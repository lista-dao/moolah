import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";
import { Liquidator } from "liquidator/Liquidator.sol";

import "./SCAddress.sol";

contract ConfigMoolah is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(MOOLAH);
  Liquidator liquidator = Liquidator(payable(LIQUIDATOR));
  PublicLiquidator publicLiquidator = PublicLiquidator(payable(PUBLIC_LIQUIDATOR));

  uint256 lltv915 = 915 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    MarketParams memory param = MarketParams({
      loanToken: USD1,
      collateralToken: COLLATERAL_USD1_USDT,
      oracle: SMART_PROVIDER_USD1_USDT,
      irm: IRM,
      lltv: lltv915
    });

    // token whitelist for liquidators
    liquidator.setTokenWhitelist(USD1, true);
    liquidator.setTokenWhitelist(USDT, true);

    // market whitelist for liquidators
    Id[] memory marketIds = new Id[](1);
    marketIds[0] = param.id();
    liquidator.setMarketWhitelist(Id.unwrap(marketIds[0]), true);

    // smart provider whitelist for public liquidator
    address[] memory providers = new address[](1);
    providers[0] = SMART_PROVIDER_USD1_USDT;
    liquidator.batchSetSmartProviders(providers, true);
    publicLiquidator.batchSetSmartProviders(providers, true);
  }
}

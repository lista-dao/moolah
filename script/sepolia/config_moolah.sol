import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import "./SCAddress.sol";

contract ConfigMoolah is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(MOOLAH);

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
    // add smart provider
    moolah.setProvider(param.id(), SMART_PROVIDER_USD1_USDT, true);

    // add flash loan token blacklist
    moolah.setFlashLoanTokenBlacklist(COLLATERAL_USD1_USDT, true);

    // batch add market liquidation whitelist
    address[][] memory list = new address[][](1);
    address[] memory liquidationWhitelist = new address[](3);
    liquidationWhitelist[0] = LIQUIDATOR;
    liquidationWhitelist[1] = PUBLIC_LIQUIDATOR;
    liquidationWhitelist[2] = deployer;
    Id[] memory marketIds = new Id[](1);
    marketIds[0] = param.id();
    list[0] = liquidationWhitelist;
    moolah.batchToggleLiquidationWhitelist(marketIds, list, true);
  }
}

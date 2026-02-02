pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Config } from "forge-std/Config.sol";

contract CreateMarketDeploy is Script, Config {
  using MarketParamsLib for MarketParams;
  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address moolahManager = 0xd7e38800201D6a42C408Bf79d8723740C4E7f631;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    _loadMarketParams();
    address[] memory loans = config.get("loan").toAddressArray();
    address[] memory collaterals = config.get("collateral").toAddressArray();
    address[] memory oracles = config.get("oracle").toAddressArray();
    address[] memory irms = config.get("irm").toAddressArray();
    uint256[] memory lltvs = config.get("lltv").toUint256Array();

    // create market
    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < loans.length; i++) {
      MarketParams memory param = MarketParams({
        loanToken: loans[i],
        collateralToken: collaterals[i],
        oracle: oracles[i],
        irm: irms[i],
        lltv: lltvs[i]
      });
      Id id = param.id();
      console.log("market id:");
      console.logBytes32(Id.unwrap(id));
      // check if market already exists
      (, , , , uint128 lastUpdate, ) = moolah.market(id);
      if (lastUpdate != 0) {
        console.log("market already exists");
        continue;
      }
      // create market
      moolah.createMarket(param);
      console.log("market created");
    }
    vm.stopBroadcast();
  }

  function _loadMarketParams() private {
    _loadConfig("./config/params.toml", true);
    string[] memory tokenNames = config.get("tokenNames").toStringArray();
    address[] memory tokens = config.get("tokens").toAddressArray();
    for (uint256 i = 0; i < tokenNames.length; i++) {
      vm.setEnv(tokenNames[i], vm.toString(tokens[i]));
    }

    string[] memory oracleNames = config.get("oracleNames").toStringArray();
    address[] memory oracles = config.get("oracles").toAddressArray();
    for (uint256 i = 0; i < oracleNames.length; i++) {
      vm.setEnv(oracleNames[i], vm.toString(oracles[i]));
    }

    string[] memory irmNames = config.get("irmNames").toStringArray();
    address[] memory irms = config.get("irms").toAddressArray();
    for (uint256 i = 0; i < irmNames.length; i++) {
      vm.setEnv(irmNames[i], vm.toString(irms[i]));
    }

    string[] memory lltvNames = config.get("lltvNames").toStringArray();
    uint256[] memory lltvs = config.get("lltvs").toUint256Array();
    for (uint256 i = 0; i < lltvNames.length; i++) {
      vm.setEnv(lltvNames[i], vm.toString(lltvs[i]));
    }

    string[] memory ptBaseOracleNames = config.get("ptBaseOracleNames").toStringArray();
    address[] memory ptBaseOracles = config.get("ptBaseOracles").toAddressArray();
    for (uint256 i = 0; i < ptBaseOracleNames.length; i++) {
      vm.setEnv(ptBaseOracleNames[i], vm.toString(ptBaseOracles[i]));
    }

    string[] memory walletNames = config.get("walletNames").toStringArray();
    address[] memory wallets = config.get("wallets").toAddressArray();
    for (uint256 i = 0; i < walletNames.length; i++) {
      vm.setEnv(walletNames[i], vm.toString(wallets[i]));
    }

    _loadConfig("./config/markets_20260203.toml", true);
  }
}

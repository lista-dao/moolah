pragma solidity 0.8.28;

import "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountMarketOracle } from "../src/oracle/PTLinearDiscountMarketOracle.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract PTLinearDiscountMarketOracleWithConfigDeploy is Script, Config {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    string memory configPath = "./config/pt_oracles_20260205.toml";

    _loadMarketParams(configPath);

    address[] memory loans = config.get("ptLoan").toAddressArray();
    address[] memory collaterals = config.get("ptCollateral").toAddressArray();
    address[] memory oracles = config.get("ptOracle").toAddressArray();
    address multiOracle = config.get("multiOracle").toAddress();
    address admin = config.get("admin").toAddress();
    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < loans.length; i++) {
      console.log(
        "Deploying PTLinearDiscountMarketOracle for loan:",
        IERC20Metadata(loans[i]).symbol(),
        " and collateral:",
        IERC20Metadata(collaterals[i]).symbol()
      );
      address proxy = deploy_PTOracle(admin, collaterals[i], loans[i], oracles[i], multiOracle);

      config.set("ptMarketOracle", vm.toString(proxy));
    }

    vm.stopBroadcast();
  }

  function deploy_PTOracle(
    address admin,
    address collateral,
    address loan,
    address collateralOracle,
    address loanOracle
  ) public returns (address) {
    // Deploy implementation
    PTLinearDiscountMarketOracle impl = new PTLinearDiscountMarketOracle();
    console.log("PTLinearDiscountMarketOracle implementation: ", address(impl));
    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        admin,
        collateral,
        collateralOracle,
        loan,
        loanOracle,
        loan,
        loanOracle
      )
    );
    console.log("PTLinearDiscountMarketOracle proxy: ", address(proxy));
    return address(proxy);
  }

  function _loadMarketParams(string memory configPath) private {
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

    _loadConfig(configPath, true);
  }
}

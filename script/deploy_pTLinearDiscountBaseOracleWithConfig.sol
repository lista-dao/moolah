pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";
import { Config } from "forge-std/Config.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILinearDiscountFactory {
  function create(address _pt, uint256 _baseDiscountPerYear) external returns (address);
}

contract PTLinearDiscountBaseOracleWithConfigDeploy is DeployBase, Config {
  address constant LINEAR_DISCOUNT_FACTORY = 0x084ceE278DA67F2B0fead8194FFe43C566E4e0B3;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    _loadMarketParams();

    address[] memory pts = config.get("pt").toAddressArray();
    uint256[] memory discounts = config.get("discount").toUint256Array();

    require(pts.length == discounts.length, "array length mismatch");

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < pts.length; i++) {
      console.log(
        "Creating LinearDiscount base oracle for:",
        IERC20Metadata(pts[i]).symbol(),
        " discountRate:",
        discounts[i]
      );
      address oracle = ILinearDiscountFactory(LINEAR_DISCOUNT_FACTORY).create(pts[i], discounts[i]);
      console.log("LinearDiscount base oracle: ", oracle);
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

    string[] memory _discountNames = config.get("discountNames").toStringArray();
    uint256[] memory _discounts = config.get("discounts").toUint256Array();
    for (uint256 i = 0; i < _discountNames.length; i++) {
      vm.setEnv(_discountNames[i], vm.toString(_discounts[i]));
    }

    _loadConfig("./config/pt_discount_oracle_20260415.toml", true);
  }
}

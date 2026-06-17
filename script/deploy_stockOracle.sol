pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StockOracle } from "../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../src/oracle/StockOracleSwitch.sol";

/// @notice Deploys StockOracleSwitch + StockOracle (UUPS proxies). All roles are granted to the
///         deployer. Run on BSC testnet (chainid 97) — DeployBase selects PRIVATE_KEY_TESTNET.
contract StockOracleDeploy is DeployBase {
  // Lista resilient oracle (Atlas-backed) — BSC testnet
  address resilientOracle = 0xb041398567ee5B01aA54A04894796c17f11cF07a;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // --- StockOracleSwitch (impl + proxy), roles: admin = manager = bot = deployer ---
    StockOracleSwitch switchImpl = new StockOracleSwitch();
    console.log("StockOracleSwitch implementation: ", address(switchImpl));
    ERC1967Proxy switchProxy = new ERC1967Proxy(
      address(switchImpl),
      abi.encodeWithSelector(switchImpl.initialize.selector, deployer, deployer, deployer)
    );
    console.log("StockOracleSwitch proxy: ", address(switchProxy));

    // --- StockOracle (impl + proxy), roles: admin = manager = deployer ---
    StockOracle oracleImpl = new StockOracle();
    console.log("StockOracle implementation: ", address(oracleImpl));
    ERC1967Proxy oracleProxy = new ERC1967Proxy(
      address(oracleImpl),
      abi.encodeWithSelector(oracleImpl.initialize.selector, deployer, deployer, address(switchProxy), resilientOracle)
    );
    console.log("StockOracle proxy: ", address(oracleProxy));

    vm.stopBroadcast();
  }
}

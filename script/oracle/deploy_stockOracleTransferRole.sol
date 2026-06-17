pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StockOracle } from "../../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";

/// @notice Hands off DEFAULT_ADMIN_ROLE + MANAGER on StockOracle and StockOracleSwitch from the
///         deployer to the timelock (admin) and the manager Safe, then renounces the deployer's roles.
///         BOT on the switch is left untouched (held by the dedicated bot wallet).
///         Fill in the proxy addresses below (printed by deploy_stockOracle.sol) before running.
contract StockOracleTransferRole is DeployBase {
  // proxies deployed by deploy_stockOracle.sol — set after deployment
  StockOracle oracle = StockOracle(0x0000000000000000000000000000000000000000);
  StockOracleSwitch stockSwitch = StockOracleSwitch(0x0000000000000000000000000000000000000000);

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // manager Safe

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    require(address(oracle) != address(0) && address(stockSwitch) != address(0), "set proxy addresses");

    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // --- StockOracle: grant to admin/manager, then renounce deployer ---
    oracle.grantRole(DEFAULT_ADMIN_ROLE, admin);
    oracle.grantRole(MANAGER, manager);
    oracle.revokeRole(MANAGER, deployer);
    oracle.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    // --- StockOracleSwitch: same. BOT stays with the dedicated bot wallet.
    //     MANAGER is the admin of BOT, so the manager Safe inherits BOT grant/revoke control. ---
    stockSwitch.grantRole(DEFAULT_ADMIN_ROLE, admin);
    stockSwitch.grantRole(MANAGER, manager);
    stockSwitch.revokeRole(MANAGER, deployer);
    stockSwitch.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

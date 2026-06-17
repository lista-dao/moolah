pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StockOracle } from "../../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";

/// @notice Hands off DEFAULT_ADMIN_ROLE + MANAGER on StockOracle and StockOracleSwitch from the
///         current holder to the timelock (admin) and the manager Safe, then renounces the holder's roles.
///         BOT: the dedicated bot wallet (0x91fC…) keeps it; the deployer's stray BOT grant is revoked.
///         PAUSER is left untouched (already the dedicated pauser wallet).
///         Run with PRIVATE_KEY set to the key that currently holds admin + manager — the deploy operator
///         0xd7e38800201D6a42C408Bf79d8723740C4E7f631 (verify with getRoleMember before running).
contract StockOracleTransferRole is DeployBase {
  // BSC mainnet proxies (deployed)
  StockOracle oracle = StockOracle(0x526D09c604A17D98cb1f260a7774A239990dbDfb);
  StockOracleSwitch stockSwitch = StockOracleSwitch(0xb4678C3E8B49d2b95Da48458f98805da193A8498);

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // manager Safe

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

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

    // --- StockOracleSwitch: same. The dedicated bot wallet keeps BOT; the deployer's stray BOT grant is
    //     revoked. MANAGER is the admin of BOT, so revoke BOT before renouncing the deployer's MANAGER. ---
    stockSwitch.grantRole(DEFAULT_ADMIN_ROLE, admin);
    stockSwitch.grantRole(MANAGER, manager);
    stockSwitch.revokeRole(BOT, deployer);
    stockSwitch.revokeRole(MANAGER, deployer);
    stockSwitch.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

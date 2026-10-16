pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { PositionMigrator } from "../src/utils/PositionMigrator.sol";

/// @dev Deploys the PositionMigrator implementation with `batchForceMigrate` and prints the TimeLock
///      batch that turns it on. Deploying changes nothing: the upgrade, BOT, deadline and the Moolah
///      MANAGER grant are all TimeLock actions on the existing proxy.
/// @dev Optional env, only for the printed calldata:
///      MIGRATION_BOT       the account granted BOT on the migrator
///      MIGRATION_DEADLINE  unix seconds; must still be in the future when the TimeLock executes
///                          (`setMigrationDeadline` rejects a past value), and `batchForceMigrate`
///                          only runs after it
contract PositionMigratorImplDeploy is DeployBase {
  address constant MIGRATOR_PROXY = 0x2B3E5b695722756130A553E9Bb5A45E16d21D0A4;
  address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  bytes32 constant MOOLAH_MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer: ", vm.addr(deployerPrivateKey));
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PositionMigrator implementation
    PositionMigrator impl = new PositionMigrator();
    console.log("PositionMigrator implementation: ", address(impl));

    vm.stopBroadcast();

    require(impl.TOKEN() == LISUSD, "TOKEN");

    address bot = vm.envOr("MIGRATION_BOT", address(0));
    uint256 deadline = vm.envOr("MIGRATION_DEADLINE", uint256(0));

    console.log("TimeLock batch, value 0 for every call");
    _action("1. upgradeToAndCall", MIGRATOR_PROXY, abi.encodeCall(impl.upgradeToAndCall, (address(impl), "")));
    if (bot != address(0)) {
      _action("2. grantRole(BOT, bot)", MIGRATOR_PROXY, abi.encodeCall(impl.grantRole, (impl.BOT(), bot)));
    } else {
      console.log("2. grantRole(BOT, bot): set MIGRATION_BOT to print");
    }
    if (deadline != 0) {
      _action("3. setMigrationDeadline", MIGRATOR_PROXY, abi.encodeCall(impl.setMigrationDeadline, (deadline)));
    } else {
      console.log("3. setMigrationDeadline: set MIGRATION_DEADLINE to print");
    }
    _action(
      "4. Moolah grantRole(MANAGER, migrator)",
      MOOLAH,
      abi.encodeCall(IAccessControl.grantRole, (MOOLAH_MANAGER, MIGRATOR_PROXY))
    );
  }

  function _action(string memory name, address target, bytes memory data) internal pure {
    console.log(name);
    console.log("  target: ", target);
    console.log("  data:");
    console.logBytes(data);
  }
}

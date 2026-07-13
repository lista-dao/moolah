pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";

/// @dev Step 3 of rollout — hand the vault's roles from the deployer to production owners,
///      then renounce every role held by the deployer. Run by the deployer right after config, before
///      the multisig wire step. Without this, a single deployer EOA can upgrade/drain/pause the vault.
///
///      Targets are the current mainnet owners (role-audit 2026-05-14):
///        DEFAULT_ADMIN_ROLE -> TimeLock (24h)         MANAGER -> 3/6 "manager" Safe
///        PAUSER -> pauser Safe                        BOT     -> liquidation hot wallet
contract LiquidationVaultTransferRole is DeployBase {
  LiquidationVault vault = LiquidationVault(payable(address(0)));

  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // DEFAULT_ADMIN
  address constant MANAGER_SAFE = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // 3/6 manager Safe
  address constant PAUSER_SAFE = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8; // pauser Safe
  address constant LIQ_BOT = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04; // liquidation hot wallet

  function run() public {
    require(address(vault) != address(0), "set vault");
    uint256 pk = _deployerKey();
    address deployer = vm.addr(pk);

    bytes32 ADMIN = 0x00;
    bytes32 MANAGER = vault.MANAGER();
    bytes32 PAUSER = vault.PAUSER();
    bytes32 BOT = vault.BOT();

    vm.startBroadcast(pk);

    // grant production owners
    vault.grantRole(MANAGER, MANAGER_SAFE);
    vault.grantRole(PAUSER, PAUSER_SAFE);
    vault.grantRole(BOT, LIQ_BOT);
    vault.grantRole(ADMIN, TIMELOCK); // grant admin LAST-but-one; renounce deployer admin last

    // renounce every deployer-held role (admin last so the grants above are authorized)
    vault.renounceRole(BOT, deployer);
    vault.renounceRole(PAUSER, deployer);
    vault.renounceRole(MANAGER, deployer);
    vault.renounceRole(ADMIN, deployer);

    vm.stopBroadcast();

    // post-conditions
    require(vault.hasRole(ADMIN, TIMELOCK) && !vault.hasRole(ADMIN, deployer), "admin handover");
    require(vault.hasRole(MANAGER, MANAGER_SAFE) && !vault.hasRole(MANAGER, deployer), "manager handover");
    require(vault.hasRole(PAUSER, PAUSER_SAFE) && !vault.hasRole(PAUSER, deployer), "pauser handover");
    require(vault.hasRole(BOT, LIQ_BOT) && !vault.hasRole(BOT, deployer), "bot handover");
    console.log("LiquidationVault roles handed over; deployer renounced all roles.");
  }
}

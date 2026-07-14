pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { StableSwapPool } from "src/dex/StableSwapPool.sol";
import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

import "./LisAsterAddress.sol";

// Step 6: revoke the deployer's roles on the pool, collateral and SmartProvider.
//         Run this ONLY AFTER 5_grant_roles.sol and after confirming the admin/pauser
//         multisigs hold their roles -- this call renounces the deployer's control.
//
// Requires DEX_LISASTER_ASTER, COLLATERAL_LISASTER_ASTER and
// SMART_PROVIDER_LISASTER_ASTER set in LisAsterAddress.sol.
//
// forge script script/smartCollateral/lisAster/6_revoke_roles.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract RevokeLisAsterAsterRoles is DeployBase {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    require(DEX_LISASTER_ASTER != address(0), "set DEX_LISASTER_ASTER first");
    require(COLLATERAL_LISASTER_ASTER != address(0), "set COLLATERAL_LISASTER_ASTER first");
    require(SMART_PROVIDER_LISASTER_ASTER != address(0), "set SMART_PROVIDER_LISASTER_ASTER first");

    vm.startBroadcast(deployerPrivateKey);

    // --- stable swap pool --- (revoke DEFAULT_ADMIN_ROLE last)
    StableSwapPool pool = StableSwapPool(DEX_LISASTER_ASTER);
    pool.revokeRole(PAUSER, deployer);
    pool.revokeRole(MANAGER, deployer);
    pool.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Revoked pool roles: ", DEX_LISASTER_ASTER);

    // --- internal StableSwapLP token (deployer holds DEFAULT_ADMIN_ROLE from factory) ---
    StableSwapLP lp = StableSwapLP(pool.token());
    lp.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Revoked StableSwapLP admin: ", pool.token());

    // --- LP collateral ---
    StableSwapLPCollateral collateral = StableSwapLPCollateral(COLLATERAL_LISASTER_ASTER);
    collateral.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Revoked collateral roles: ", COLLATERAL_LISASTER_ASTER);

    // --- SmartProvider ---
    SmartProvider provider = SmartProvider(payable(SMART_PROVIDER_LISASTER_ASTER));
    provider.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Revoked provider roles: ", SMART_PROVIDER_LISASTER_ASTER);

    vm.stopBroadcast();

    console.log("revoke roles done!");
  }
}

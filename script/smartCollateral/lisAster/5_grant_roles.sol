pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { StableSwapPool } from "src/dex/StableSwapPool.sol";
import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

import "./LisAsterAddress.sol";

// Step 5: grant roles on the pool, collateral and SmartProvider to the admin/pauser
//         multisigs. Run this BEFORE 6_revoke_roles.sol so the deployer keeps admin
//         until the new roles are confirmed.
//
// Requires DEX_LISASTER_ASTER, COLLATERAL_LISASTER_ASTER and
// SMART_PROVIDER_LISASTER_ASTER set in LisAsterAddress.sol.
//
// forge script script/smartCollateral/lisAster/5_grant_roles.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract GrantLisAsterAsterRoles is DeployBase {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant TRANSFERER = keccak256("TRANSFERER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    require(DEX_LISASTER_ASTER != address(0), "set DEX_LISASTER_ASTER first");
    require(COLLATERAL_LISASTER_ASTER != address(0), "set COLLATERAL_LISASTER_ASTER first");
    require(SMART_PROVIDER_LISASTER_ASTER != address(0), "set SMART_PROVIDER_LISASTER_ASTER first");

    vm.startBroadcast(deployerPrivateKey);

    // --- stable swap pool ---
    StableSwapPool pool = StableSwapPool(DEX_LISASTER_ASTER);
    pool.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    pool.grantRole(MANAGER, MANAGER_ADDR); // MANAGER -> 0x8d38...b0c6 multisig
    pool.grantRole(PAUSER, PAUSER_ADDR);
    console.log("Granted pool roles: ", DEX_LISASTER_ASTER);

    // --- internal StableSwapLP token (deployer holds DEFAULT_ADMIN_ROLE from factory) ---
    StableSwapLP lp = StableSwapLP(pool.token());
    lp.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    console.log("Granted StableSwapLP admin: ", pool.token());

    // --- LP collateral ---
    StableSwapLPCollateral collateral = StableSwapLPCollateral(COLLATERAL_LISASTER_ASTER);
    collateral.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    collateral.grantRole(MANAGER, MANAGER_ADDR); // MANAGER -> 0x8d38...b0c6 multisig
    collateral.grantRole(TRANSFERER, MOOLAH); // TRANSFERER -> Moolah contract
    console.log("Granted collateral roles: ", COLLATERAL_LISASTER_ASTER);

    // --- SmartProvider ---
    SmartProvider provider = SmartProvider(payable(SMART_PROVIDER_LISASTER_ASTER));
    provider.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    provider.grantRole(MANAGER, MANAGER_ADDR); // MANAGER -> 0x8d38...b0c6 multisig
    console.log("Granted provider roles: ", SMART_PROVIDER_LISASTER_ASTER);

    vm.stopBroadcast();

    console.log("grant roles done! NEXT: run 6_revoke_roles.sol once confirmed");
  }
}

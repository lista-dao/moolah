pragma solidity 0.8.34;

// Shared smart-collateral addresses (MOOLAH, SS_FACTORY, SS_INFO, RESILIENT_ORACLE, IRM, roles, ...)
import "../SCAddress.sol";

// ---------------------------------------------------------------------------
// lisAster / Aster smart-collateral deployment address book
// ---------------------------------------------------------------------------

// Aster token (loan token)
address constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;

// lisAster token
address constant LISASTER = 0xa17A497D20cC143508FE3b63578b13ba6b9c9f06;

// -------- Filled in as each deploy step below is broadcast --------

// [step 1] lisAster <> Aster stable swap pool
address constant DEX_LISASTER_ASTER = address(0); // TODO: set after 1_create_stableSwapPair

// [step 1] lisAster <> Aster internal StableSwapLP token
address constant LP_LISASTER_ASTER = address(0); // TODO: set after 1_create_stableSwapPair

// [step 2] lisAster <> Aster SmartLP collateral (Moolah collateral token)
address constant COLLATERAL_LISASTER_ASTER = address(0); // TODO: set after 2_deploy_lp_collateral

// [step 3] lisAster <> Aster SmartProvider (also the market oracle)
address constant SMART_PROVIDER_LISASTER_ASTER = address(0); // TODO: set after 3_deploy_smartProvider

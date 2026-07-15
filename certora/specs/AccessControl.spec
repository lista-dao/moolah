// SPDX-License-Identifier: GPL-2.0-or-later
//
// Access-control / upgradeability rules specific to Moolah (Morpho Blue has none of these).
// The generic invariants in the other specs filter the upgrade/admin operations out via
// ProxyFilters.spec; this spec verifies their authorization gates directly.

methods {
    function hasRole(bytes32, address) external returns bool envfree;
    function DEFAULT_ADMIN_ROLE() external returns bytes32 envfree;
    function MANAGER() external returns bytes32 envfree;
    function PAUSER() external returns bytes32 envfree;
}

// Only an account holding DEFAULT_ADMIN_ROLE may authorize a UUPS implementation upgrade.
// We target the `_authorizeUpgrade` gate (via the harness wrapper) rather than
// `upgradeToAndCall`, whose `onlyProxy` guard reverts unconditionally on the directly-verified
// implementation and would make this rule vacuous.
rule onlyAdminCanAuthorizeUpgrade(env e, address newImplementation) {
    authorizeUpgrade_@withrevert(e, newImplementation);
    assert !lastReverted => hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
}

// Only PAUSER may pause the contract.
rule onlyPauserCanPause(env e) {
    pause@withrevert(e);
    assert !lastReverted => hasRole(PAUSER(), e.msg.sender);
}

// Only MANAGER may unpause the contract.
rule onlyManagerCanUnpause(env e) {
    unpause@withrevert(e);
    assert !lastReverted => hasRole(MANAGER(), e.msg.sender);
}

// Only MANAGER may change the minimum loan value.
rule onlyManagerCanSetMinLoanValue(env e, uint256 newValue) {
    setMinLoanValue@withrevert(e, newValue);
    assert !lastReverted => hasRole(MANAGER(), e.msg.sender);
}

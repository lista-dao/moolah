// SPDX-License-Identifier: GPL-2.0-or-later
//
// Shared method filters for Moolah's proxy / upgradeability machinery.
//
// Unlike Morpho Blue, Moolah is a UUPS-upgradeable contract (UUPSUpgradeable +
// AccessControlEnumerableUpgradeable + Pausable + ReentrancyGuard). The functions captured
// below either replace the implementation or reset contract state, so they must be excluded
// from generic parametric (`method f`) invariants — otherwise the prover surfaces spurious
// counterexamples in which an upgrade/initialize havocs the whole state. These operations are
// instead checked by dedicated rules (see AccessControl.spec).
//
//   - upgradeToAndCall    : UUPS upgrade entry point; delegatecalls a new implementation.
//   - initialize          : one-shot initializer; would reset roles/state.
//   - setUpInitializedState: harness-only helper (MoolahHarness) that seeds an initialized
//                            state for verification; not part of Moolah.
//   - authorizeUpgrade_   : harness-only wrapper over _authorizeUpgrade; not part of Moolah.

definition isUpgradeOrInit(method f) returns bool =
    f.selector == sig:upgradeToAndCall(address,bytes).selector ||
    f.selector == sig:initialize(address,address,address,uint256).selector ||
    f.selector == sig:setUpInitializedState(address,address,address,uint256).selector ||
    f.selector == sig:authorizeUpgrade_(address).selector;

// Role administration inherited from AccessControlEnumerableUpgradeable. Filter these out of
// accounting/health invariants (they never touch market/position state), but keep them in
// rules that reason about access control itself.
definition isAccessControl(method f) returns bool =
    f.selector == sig:grantRole(bytes32,address).selector ||
    f.selector == sig:revokeRole(bytes32,address).selector ||
    f.selector == sig:renounceRole(bytes32,address).selector;

// Broker exclusion. Moolah lets a market be managed by a LendingBroker: when a broker is set
// for a market id, the broker REPLACES the normal supply/borrow/repay flow and the health
// computation pulls the position's debt from the broker (PriceLib._getBrokerTotalDebt) via an
// external call. Verifying broker-managed markets is out of scope for now (large surface, many
// external calls → prover havoc). We exclude brokers in two ways:
//   1. isBrokerFunction filters the broker-only entry points out of parametric `method f` rules.
//   2. The Sload hook below assumes no market has a broker, so every broker branch in
//      borrow/repay/_isHealthy/_getPrice takes the non-broker path and makes no broker calls.
// (Providers use the same pattern and can be excluded analogously if needed.)
definition isBrokerFunction(method f) returns bool =
    f.selector == sig:setMarketBroker(MoolahHarness.Id, address, bool).selector ||
    f.selector == sig:liquidateBrokerPosition(MoolahHarness.MarketParams, address, uint256).selector;

hook Sload address broker brokers[KEY MoolahHarness.Id id] {
    require broker == 0;
}

// Provider exclusion. Moolah also lets a Provider sit in front of a market's loan/collateral
// token: when providers[id][token] is set, the provider may act in place of the user in
// borrow/withdraw/supplyCollateral (authorization branches, no external call) and, in
// liquidate, Moolah calls IProvider(provider).liquidate(id, borrower) (an external call). We
// scope provider-managed markets out the same way as brokers:
//   1. isProviderFunction filters the admin entry point (setProvider, which also calls
//      IProvider(provider).TOKEN()) out of parametric `method f` rules.
//   2. The Sload hook below assumes no market has a provider, so the provider branches take the
//      standard (non-provider) authorization path and liquidate makes no provider call.
definition isProviderFunction(method f) returns bool =
    f.selector == sig:setProvider(MoolahHarness.Id, address, bool).selector;

hook Sload address provider providers[KEY MoolahHarness.Id id][KEY address token] {
    require provider == 0;
}

// Whitelist batch admin: loops over dynamic arrays and only touches the liquidation whitelist
// (never supply/borrow/collateral accounting). Excluding it keeps the generic rules/invariants
// free of loop-unwinding noise — the prover would otherwise unroll its nested loops and fail the
// unwinding condition (see also "optimistic_loop" in the confs, which covers the remaining
// library loops such as EnumerableSet).
definition isWhitelistBatch(method f) returns bool =
    f.selector == sig:batchToggleLiquidationWhitelist(MoolahHarness.Id[], address[][], bool).selector;

// Combined exclusion: proxy/upgrade/init + broker + provider entry points + whitelist batch. Use
// this in the `filtered` clause of every parametric rule AND every invariant — invariants check
// preservation across all methods, so without it the prover runs upgradeToAndCall/initialize/
// setMarketBroker/setProvider/liquidateBrokerPosition/batchToggleLiquidationWhitelist against the
// invariant and reports spurious havoc breaks (or loop-unwinding failures).
definition isExcludedOp(method f) returns bool =
    isUpgradeOrInit(f) || isBrokerFunction(f) || isProviderFunction(f) || isWhitelistBatch(f);

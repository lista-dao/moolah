// SPDX-License-Identifier: GPL-2.0-or-later
import "ProxyFilters.spec";

methods {

    function _.borrowRate(MoolahHarness.MarketParams marketParams, MoolahHarness.Market) external => summaryBorrowRate() expect uint256;
}

persistent ghost bool delegateCall;
persistent ghost bool callIsBorrowRate;
// True when storage has been accessed with either a SSTORE or a SLOAD.
persistent ghost bool hasAccessedStorage;
// True when a CALL has been done after storage has been accessed.
persistent ghost bool hasCallAfterAccessingStorage;
// True when storage has been accessed, after which an external call is made, followed by accessing storage again.
persistent ghost bool hasReentrancyUnsafeCall;

function summaryBorrowRate() returns uint256 {
    uint256 result;
    callIsBorrowRate = true;
    return result;
}

hook ALL_SSTORE(uint loc, uint v) {
    hasAccessedStorage = true;
    hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
}

hook ALL_SLOAD(uint loc) uint v {
    hasAccessedStorage = true;
    hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
}

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (callIsBorrowRate) {
        // The calls to borrow rate are trusted and don't count.
        callIsBorrowRate = false;
    } else {
        hasCallAfterAccessingStorage = hasAccessedStorage;
    }
}

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    delegateCall = true;
}

// Check that no function is accessing storage, then making an external CALL other than to the IRM, and accessing storage again.
rule reentrancySafe(method f, env e, calldataarg data) filtered { f -> !isExcludedOp(f) } {
    // Set up the initial state.
    require !callIsBorrowRate;
    require !hasAccessedStorage && !hasCallAfterAccessingStorage && !hasReentrancyUnsafeCall;
    f(e, data);
    assert !hasReentrancyUnsafeCall;
}

// Check that the contract performs no delegatecalls outside its UUPS upgrade path.
// NOTE: unlike Morpho Blue, Moolah is upgradeable, so `upgradeToAndCall` legitimately
// delegatecalls the new implementation; it is filtered out and checked in AccessControl.spec.
rule noDelegateCalls(method f, env e, calldataarg data) filtered { f -> !isExcludedOp(f) } {
    // Set up the initial state.
    require !delegateCall;
    f(e, data);
    assert !delegateCall;
}

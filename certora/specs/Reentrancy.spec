// SPDX-License-Identifier: GPL-2.0-or-later
import "ProxyFilters.spec";

using PriceLib as priceLib;

methods {
    function _.borrowRate(MoolahHarness.MarketParams marketParams, MoolahHarness.Market) external => summaryBorrowRate() expect uint256;
}

// OZ ReentrancyGuardUpgradeable: ERC-7201 _status slot and its values.
definition GUARD_SLOT() returns uint256 = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
definition NOT_ENTERED() returns uint256 = 1;
definition ENTERED() returns uint256 = 2;

persistent ghost bool delegateCall;
persistent ghost bool callIsBorrowRate;
// Mirror of the ReentrancyGuard _status slot.
persistent ghost uint256 lockStatus;
// Stays true as long as every untrusted CALL happens while the mutex is held;
// flips to false permanently once a call is made without the lock.
persistent ghost bool isReentrancySafeCall;
// CEI tracking, used for flashLoan which deliberately takes no lock.
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
    if (loc == GUARD_SLOT()) {
        lockStatus = v;
    } else {
        hasAccessedStorage = true;
        hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
    }
}

hook ALL_SLOAD(uint loc) uint v {
    if (loc == GUARD_SLOT()) {
        // Tie the mirror to the value actually read from storage.
        require v == lockStatus;
    } else {
        hasAccessedStorage = true;
        hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
    }
}

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (callIsBorrowRate) {
        // The calls to borrow rate are trusted and don't count.
        callIsBorrowRate = false;
    } else {
        if (lockStatus != ENTERED()) {
            isReentrancySafeCall = false;
        }
        hasCallAfterAccessingStorage = hasAccessedStorage;
    }
}

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    // Public library functions compile to delegatecalls into the linked
    // PriceLib; that is Moolah's only legitimate delegatecall target here
    // (the UUPS upgrade path is filtered separately).
    if (addr != priceLib) {
        delegateCall = true;
    }
}

// Moolah's reentrancy protection is the ReentrancyGuard mutex, not Morpho Blue's strict
// CEI ordering: check that every untrusted external call happens while the mutex is held,
// so the callee cannot reenter any nonReentrant entry point. flashLoan deliberately takes
// no lock (its callback is meant to reenter, e.g. PositionMigrator) and is checked
// separately below.
rule reentrancySafe(method f, env e, calldataarg data)
filtered { f -> !isExcludedOp(f) && f.selector != sig:flashLoan(address,uint256,bytes).selector } {
    // Set up the initial state.
    require !callIsBorrowRate;
    require lockStatus == NOT_ENTERED();
    require isReentrancySafeCall;
    f(e, data);
    assert isReentrancySafeCall;
}

// Check that the mutex is released again by the end of every entry point.
rule lockAlwaysReleased(method f, env e, calldataarg data) filtered { f -> !isExcludedOp(f) } {
    require lockStatus == NOT_ENTERED();
    f(e, data);
    assert lockStatus == NOT_ENTERED();
}

// flashLoan holds no lock, so it must satisfy strict CEI instead: no storage access after
// its external calls, hence a reentering callback cannot invalidate flashLoan's own state
// assumptions.
rule flashLoanReentrancySafe(env e, address token, uint256 assets, bytes data) {
    // Set up the initial state.
    require !callIsBorrowRate;
    require !hasAccessedStorage && !hasCallAfterAccessingStorage && !hasReentrancyUnsafeCall;
    flashLoan(e, token, assets, data);
    assert !hasReentrancyUnsafeCall;
}

// Check that the contract performs no delegatecalls other than into the linked PriceLib
// library (public library functions compile to delegatecalls) and its UUPS upgrade path.
// NOTE: unlike Morpho Blue, Moolah is upgradeable, so `upgradeToAndCall` legitimately
// delegatecalls the new implementation; it is filtered out and checked in AccessControl.spec.
rule noDelegateCalls(method f, env e, calldataarg data) filtered { f -> !isExcludedOp(f) } {
    // Set up the initial state.
    require !delegateCall;
    f(e, data);
    assert !delegateCall;
}

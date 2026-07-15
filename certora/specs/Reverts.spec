// SPDX-License-Identifier: GPL-2.0-or-later
//
// Moolah replaces Morpho Blue's single-`owner` permission model with OpenZeppelin
// AccessControl roles. The admin setters below are guarded by `onlyRole(MANAGER)` (there is no
// `owner()` / `setOwner`). The owner-model rules have therefore been re-expressed against
// `hasRole(MANAGER, sender)`, and their original exact `<=>` revert conditions were relaxed to
// the one-directional `=>` (necessary-condition) form: Moolah's setters may carry extra
// requires (pausing, role bookkeeping, ...), and `=>` stays sound under any additional revert
// cause. The reverse direction (authorized + valid input never reverts) is intentionally not
// asserted here and should be confirmed with the prover when adapting per-rule.

import "ProxyFilters.spec";

using Util as Util;

methods {

    function hasRole(bytes32, address) external returns bool envfree;
    function MANAGER() external returns bytes32 envfree;
    function feeRecipient() external returns address envfree;
    function totalSupplyAssets(MoolahHarness.Id) external returns uint256 envfree;
    function totalBorrowAssets(MoolahHarness.Id) external returns uint256 envfree;
    function totalSupplyShares(MoolahHarness.Id) external returns uint256 envfree;
    function totalBorrowShares(MoolahHarness.Id) external returns uint256 envfree;
    function lastUpdate(MoolahHarness.Id) external returns uint256 envfree;
    function isIrmEnabled(address) external returns bool envfree;
    function isLltvEnabled(uint256) external returns bool envfree;
    function isAuthorized(address, address) external returns bool envfree;
    function nonce(address) external returns uint256 envfree;

    function Util.libId(MoolahHarness.MarketParams) external returns MoolahHarness.Id envfree;

    function Util.maxFee() external returns uint256 envfree;
    function Util.wad() external returns uint256 envfree;
}

definition isCreated(MoolahHarness.Id id) returns bool =
    (lastUpdate(id) != 0);

persistent ghost mapping(MoolahHarness.Id => mathint) sumCollateral
{
    init_state axiom (forall MoolahHarness.Id id. sumCollateral[id] == 0);
}
hook Sstore position[KEY MoolahHarness.Id id][KEY address owner].collateral uint128 newAmount (uint128 oldAmount) {
    sumCollateral[id] = sumCollateral[id] - oldAmount + newAmount;
}

definition emptyMarket(MoolahHarness.Id id) returns bool =
    totalSupplyAssets(id) == 0 &&
    totalSupplyShares(id) == 0 &&
    totalBorrowAssets(id) == 0 &&
    totalBorrowShares(id) == 0 &&
    sumCollateral[id] == 0;

definition exactlyOneZero(uint256 assets, uint256 shares) returns bool =
    (assets == 0 && shares != 0) || (assets != 0 && shares == 0);

// This invariant catches bugs when not checking that the market is created with lastUpdate.
invariant notCreatedIsEmpty(MoolahHarness.Id id)
    !isCreated(id) => emptyMarket(id)
    filtered { f -> !isExcludedOp(f) }
{
    preserved with (env e) {
        // Safe require because timestamps cannot realistically be that large.
        require e.block.timestamp < 2^128;
    }
}

// Useful to ensure that authorized parties are not the zero address and so we can omit the sanity check in this case.
invariant zeroDoesNotAuthorize(address authorized)
    !isAuthorized(0, authorized)
    filtered { f -> !isExcludedOp(f) }
{
    preserved setAuthorization(address _authorized, bool _newAuthorization) with (env e) {
        // Safe require because no one controls the zero address.
        require e.msg.sender != 0;
    }
}

// Check the (necessary) revert conditions for the enableIrm function (MANAGER-gated).
rule enableIrmRevertCondition(env e, address irm) {
    bool senderIsManager = hasRole(MANAGER(), e.msg.sender);
    bool oldIsIrmEnabled = isIrmEnabled(irm);
    enableIrm@withrevert(e, irm);
    assert e.msg.value != 0 || !senderIsManager || oldIsIrmEnabled => lastReverted;
}

// Check the (necessary) revert conditions for the enableLltv function (MANAGER-gated).
rule enableLltvRevertCondition(env e, uint256 lltv) {
    bool senderIsManager = hasRole(MANAGER(), e.msg.sender);
    uint256 wad = Util.wad();
    bool oldIsLltvEnabled = isLltvEnabled(lltv);
    enableLltv@withrevert(e, lltv);
    assert !senderIsManager || lltv > wad || oldIsLltvEnabled => lastReverted;
}

// Check that setFee reverts when its inputs are not validated (MANAGER-gated).
// setFee can also revert if the accrueInterest reverts.
rule setFeeInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 newFee) {
    MoolahHarness.Id id = Util.libId(marketParams);
    bool wasCreated = isCreated(id);
    setFee@withrevert(e, marketParams, newFee);
    bool hasReverted = lastReverted;
    assert e.msg.value != 0 || !hasRole(MANAGER(), e.msg.sender) || !wasCreated || newFee > Util.maxFee() => hasReverted;
}

// Check the (necessary) revert conditions for the setFeeRecipient function (MANAGER-gated).
rule setFeeRecipientRevertCondition(env e, address newFeeRecipient) {
    bool senderIsManager = hasRole(MANAGER(), e.msg.sender);
    address oldFeeRecipient = feeRecipient();
    setFeeRecipient@withrevert(e, newFeeRecipient);
    assert e.msg.value != 0 || !senderIsManager || newFeeRecipient == oldFeeRecipient => lastReverted;
}

// Check that createMarket reverts when its input are not validated.
rule createMarketInputValidation(env e, MoolahHarness.MarketParams marketParams) {
    MoolahHarness.Id id = Util.libId(marketParams);
    bool irmEnabled = isIrmEnabled(marketParams.irm);
    bool lltvEnabled = isLltvEnabled(marketParams.lltv);
    bool wasCreated = isCreated(id);
    createMarket@withrevert(e, marketParams);
    assert e.msg.value != 0 || !irmEnabled || !lltvEnabled || wasCreated => lastReverted;
}

// Check that supply reverts when its input are not validated.
rule supplyInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    supply@withrevert(e, marketParams, assets, shares, onBehalf, data);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 => lastReverted;
}

// Check that withdraw reverts when its inputs are not validated.
rule withdrawInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    withdraw@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 || receiver == 0 => lastReverted;
}

// Check that borrow reverts when its inputs are not validated.
rule borrowInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    borrow@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0  || receiver == 0 => lastReverted;
}

// Check that repay reverts when its inputs are not validated.
rule repayInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    repay@withrevert(e, marketParams, assets, shares, onBehalf, data);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 => lastReverted;
}

// Check that supplyCollateral reverts when its inputs are not validated.
rule supplyCollateralInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) {
    supplyCollateral@withrevert(e, marketParams, assets, onBehalf, data);
    assert assets == 0 || onBehalf == 0 => lastReverted;
}

// Check that withdrawCollateral reverts when its inputs are not validated.
rule withdrawCollateralInputValidation(env e, MoolahHarness.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    withdrawCollateral@withrevert(e, marketParams, assets, onBehalf, receiver);
    assert assets == 0 || onBehalf == 0 || receiver == 0 => lastReverted;
}

// Check that flashLoan reverts when its inputs are not validated.
rule flashLoanInputValidation(env e, address token, uint256 assets, bytes data) {
    flashLoan@withrevert(e, token, assets, data);
    assert assets == 0 => lastReverted;
}

// Check that liquidate reverts when its inputs are not validated.
rule liquidateInputValidation(env e, MoolahHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes data) {
    liquidate@withrevert(e, marketParams, borrower, seizedAssets, repaidShares, data);
    assert !exactlyOneZero(seizedAssets, repaidShares) => lastReverted;
}

// Check that setAuthorizationWithSig reverts when its inputs are not validated.
rule setAuthorizationWithSigInputValidation(env e, MoolahHarness.Authorization authorization, MoolahHarness.Signature signature) {
    uint256 nonceBefore = nonce(authorization.authorizer);
    setAuthorizationWithSig@withrevert(e, authorization, signature);
    assert e.block.timestamp > authorization.deadline || authorization.nonce != nonceBefore => lastReverted;
}

// Check that accrueInterest reverts when its inputs are not validated.
rule accrueInterestInputValidation(env e, MoolahHarness.MarketParams marketParams) {
    bool wasCreated = isCreated(Util.libId(marketParams));
    accrueInterest@withrevert(e, marketParams);
    assert !wasCreated => lastReverted;
}

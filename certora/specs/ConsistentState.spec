// SPDX-License-Identifier: GPL-2.0-or-later
import "ProxyFilters.spec";

using Util as Util;

methods {

    function supplyShares(MoolahHarness.Id, address) external returns (uint256) envfree;
    function borrowShares(MoolahHarness.Id, address) external returns (uint256) envfree;
    function collateral(MoolahHarness.Id, address) external returns (uint256) envfree;
    function totalSupplyAssets(MoolahHarness.Id) external returns (uint256) envfree;
    function totalSupplyShares(MoolahHarness.Id) external returns (uint256) envfree;
    function totalBorrowAssets(MoolahHarness.Id) external returns (uint256) envfree;
    function totalBorrowShares(MoolahHarness.Id) external returns (uint256) envfree;
    function fee(MoolahHarness.Id) external returns (uint256) envfree;
    function defaultMarketFee() external returns (uint256) envfree;
    function lastUpdate(MoolahHarness.Id) external returns (uint256) envfree;
    function isIrmEnabled(address) external returns (bool) envfree;
    function isLltvEnabled(uint256) external returns (bool) envfree;
    function isAuthorized(address, address) external returns (bool) envfree;
    function idToMarketParams_(MoolahHarness.Id) external returns (MoolahHarness.MarketParams) envfree;
    function nonce(address) external returns (uint256) envfree;

    function Util.maxFee() external returns (uint256) envfree;
    function Util.wad() external returns (uint256) envfree;
    function Util.libId(MoolahHarness.MarketParams) external returns (MoolahHarness.Id) envfree;

    function _.borrowRate(MoolahHarness.MarketParams, MoolahHarness.Market) external => HAVOC_ECF;

    function SafeTransferLib.safeTransfer(address token, address to, uint256 value) internal => summarySafeTransferFrom(token, currentContract, to, value);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => summarySafeTransferFrom(token, from, to, value);
}

persistent ghost mapping(MoolahHarness.Id => mathint) sumSupplyShares {
    init_state axiom (forall MoolahHarness.Id id. sumSupplyShares[id] == 0);
}

persistent ghost mapping(MoolahHarness.Id => mathint) sumBorrowShares {
    init_state axiom (forall MoolahHarness.Id id. sumBorrowShares[id] == 0);
}

persistent ghost mapping(MoolahHarness.Id => mathint) sumCollateral {
    init_state axiom (forall MoolahHarness.Id id. sumCollateral[id] == 0);
}

persistent ghost mapping(address => mathint) balance {
    init_state axiom (forall address token. balance[token] == 0);
}

persistent ghost mapping(address => mathint) idleAmount {
    init_state axiom (forall address token. idleAmount[token] == 0);
}

hook Sstore position[KEY MoolahHarness.Id id][KEY address owner].supplyShares uint256 newShares (uint256 oldShares) {
    sumSupplyShares[id] = sumSupplyShares[id] - oldShares + newShares;
}

hook Sstore position[KEY MoolahHarness.Id id][KEY address owner].borrowShares uint128 newShares (uint128 oldShares) {
    sumBorrowShares[id] = sumBorrowShares[id] - oldShares + newShares;
}

hook Sstore position[KEY MoolahHarness.Id id][KEY address owner].collateral uint128 newAmount (uint128 oldAmount) {
    sumCollateral[id] = sumCollateral[id] - oldAmount + newAmount;
    idleAmount[idToMarketParams_(id).collateralToken] = idleAmount[idToMarketParams_(id).collateralToken] - oldAmount + newAmount;
}

hook Sstore market[KEY MoolahHarness.Id id].totalSupplyAssets uint128 newAmount (uint128 oldAmount) {
    idleAmount[idToMarketParams_(id).loanToken] = idleAmount[idToMarketParams_(id).loanToken] - oldAmount + newAmount;
}

hook Sstore market[KEY MoolahHarness.Id id].totalBorrowAssets uint128 newAmount (uint128 oldAmount) {
    idleAmount[idToMarketParams_(id).loanToken] = idleAmount[idToMarketParams_(id).loanToken] + oldAmount - newAmount;
}

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    if (from == currentContract) {
        // Safe require because the reference implementation would revert.
        balance[token] = require_uint256(balance[token] - amount);
    }
    if (to == currentContract) {
        // Safe require because the reference implementation would revert.
        balance[token] = require_uint256(balance[token] + amount);
    }
}

definition isCreated(MoolahHarness.Id id) returns bool = lastUpdate(id) != 0;

// The fee assigned to newly created markets (defaultMarketFee) is bounded by setDefaultMarketFee
// (require newFee <= MAX_FEE). Needed to make feeInRange inductive across createMarket.
invariant defaultMarketFeeInRange()
    defaultMarketFee() <= Util.maxFee()
    filtered { f -> !isExcludedOp(f) }

// Check that the fee is always lower than the max fee constant.
invariant feeInRange(MoolahHarness.Id id)
    fee(id) <= Util.maxFee()
    filtered { f -> !isExcludedOp(f) }
    {
        // createMarket sets market[id].fee = defaultMarketFee, which is itself bounded.
        preserved createMarket(MoolahHarness.MarketParams marketParams) with (env e) {
            requireInvariant defaultMarketFeeInRange();
        }
    }

// Check that the accounting of totalSupplyShares is correct.
invariant sumSupplySharesCorrect(MoolahHarness.Id id)
    to_mathint(totalSupplyShares(id)) == sumSupplyShares[id]
    filtered { f -> !isExcludedOp(f) }

// Check that the accounting of totalBorrowShares is correct.
invariant sumBorrowSharesCorrect(MoolahHarness.Id id)
    to_mathint(totalBorrowShares(id)) == sumBorrowShares[id]
    filtered { f -> !isExcludedOp(f) }

// Check that a market only allows borrows up to the total supply.
// This invariant shows that markets are independent, tokens from one market cannot be taken by interacting with another market.
invariant borrowLessThanSupply(MoolahHarness.Id id)
    totalBorrowAssets(id) <= totalSupplyAssets(id)
    filtered { f -> !isExcludedOp(f) }

// Check correctness of applying idToMarketParams() to an identifier.
invariant hashOfMarketParamsOf(MoolahHarness.Id id)
    isCreated(id) => Util.libId(idToMarketParams_(id)) == id
    filtered { f -> !isExcludedOp(f) }

// Check correctness of applying id() to a market params.
// This invariant is useful in the following rule, to link an id back to a market.
invariant marketParamsOfHashOf(MoolahHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => idToMarketParams_(Util.libId(marketParams)) == marketParams
    filtered { f -> !isExcludedOp(f) }

// Check that the idle amount on the singleton is greater to the sum amount, that is the sum over all the markets of the total supply plus the total collateral minus the total borrow.
invariant idleAmountLessThanBalance(address token)
    idleAmount[token] <= balance[token]
    filtered { f -> !isExcludedOp(f) }
    {
        // Safe requires on the sender because the contract cannot call the function itself.
        preserved supply(MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved withdraw(MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved borrow(MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved repay(MoolahHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved supplyCollateral(MoolahHarness.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved withdrawCollateral(MoolahHarness.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved liquidate(MoolahHarness.MarketParams marketParams, address _b, uint256 shares, uint256 receiver, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
    }

// Check that a market can only exist if its LLTV is enabled.
invariant onlyEnabledLltv(MoolahHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => isLltvEnabled(marketParams.lltv)
    filtered { f -> !isExcludedOp(f) }

invariant lltvSmallerThanWad(uint256 lltv)
    isLltvEnabled(lltv) => lltv <= Util.wad()
    filtered { f -> !isExcludedOp(f) }

// Check that a market can only exist if its IRM is enabled.
invariant onlyEnabledIrm(MoolahHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => isIrmEnabled(marketParams.irm)
    filtered { f -> !isExcludedOp(f) }

// Check the pseudo-injectivity of the hashing function id().
rule libIdUnique() {
    MoolahHarness.MarketParams marketParams1;
    MoolahHarness.MarketParams marketParams2;

    // Assume that arguments are the same.
    require Util.libId(marketParams1) == Util.libId(marketParams2);

    assert marketParams1 == marketParams2;
}

// Check that only the user is able to change who is authorized to manage his position.
rule onlyUserCanAuthorizeWithoutSig(env e, method f, calldataarg data) filtered { f -> !f.isView && !isExcludedOp(f) && f.selector != sig:setAuthorizationWithSig(MoolahHarness.Authorization memory, MoolahHarness.Signature calldata).selector } {
    address user;
    address someone;

    // Assume that it is another user that is interacting with Morpho.
    require user != e.msg.sender;

    bool authorizedBefore = isAuthorized(user, someone);

    f(e, data);

    bool authorizedAfter = isAuthorized(user, someone);

    assert authorizedAfter == authorizedBefore;
}

// Check that only authorized users are able to decrease supply shares of a position.
rule userCannotLoseSupplyShares(env e, method f, calldataarg data) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint sharesBefore = supplyShares(id, user);

    f(e, data);

    mathint sharesAfter = supplyShares(id, user);

    assert sharesAfter >= sharesBefore;
}

// Check that only authorized users are able to increase the borrow shares of a position.
rule userCannotGainBorrowShares(env e, method f, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint sharesBefore = borrowShares(id, user);

    f(e, args);

    mathint sharesAfter = borrowShares(id, user);

    assert sharesAfter <= sharesBefore;
}

// Check that users cannot lose collateral by unauthorized parties except in case of a liquidation.
rule userCannotLoseCollateralExceptLiquidate(env e, method f, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) && f.selector != sig:liquidate(MoolahHarness.MarketParams, address, uint256, uint256, bytes).selector } {
    MoolahHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint collateralBefore = collateral(id, user);

    f(e, args);

    mathint collateralAfter = collateral(id, user);

    assert collateralAfter >= collateralBefore;
}

// Check that users cannot lose collateral by unauthorized parties if they have no outstanding debt.
rule userWithoutBorrowCannotLoseCollateral(env e, method f, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    // Assume that the user has no outstanding debt.
    require borrowShares(id, user) == 0;

    mathint collateralBefore = collateral(id, user);

    f(e, args);

    mathint collateralAfter = collateral(id, user);

    assert collateralAfter >= collateralBefore;
}

// Invariant checking that the last updated time is never greater than the current time.
rule noTimeTravel(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;

    // Assume the property before the interaction.
    require lastUpdate(id) <= e.block.timestamp;

    f(e, args);

    assert lastUpdate(id) <= e.block.timestamp;
}

// Invariant checking that the last updated time is never zero.
rule lastUpdateNonZero(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;

    // Assume the timestamp is not extremely far in the future.
    require e.block.timestamp <= max_uint128;

    // Assume the property before the interaction.
    require lastUpdate(id) != 0;

    f(e, args);

    assert lastUpdate(id) != 0;
}

// Invariant checking that the last updated time never decreases.
rule lastUpdateCannotDecrease(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;

    // Assume the timestamp is not extremely far in the future.
    require e.block.timestamp <= max_uint128;
    uint256 lastUpdateBefore = lastUpdate(id);

    f(e, args);

    uint256 lastUpdateAfter = lastUpdate(id);
    assert lastUpdateAfter >= lastUpdateBefore;
}

// Invariant checking that IRM cannot be disabled once enabled.
rule irmCannotBeDisabled(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    address irm;

    // Assume the property before the interaction.
    require isIrmEnabled(irm);

    f(e, args);

    assert isIrmEnabled(irm);
}

// Invariant checking that LLTV cannot be disabled once enabled.
rule lltvCannotBeDisabled(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    uint256 lltv;

    // Assume the property before the interaction.
    require isLltvEnabled(lltv);

    f(e, args);

    assert isLltvEnabled(lltv);
}

// Invariant checking that market parameters for a created market cannot change.
rule idToMarketParamsForCreatedMarketCannotChange(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    MoolahHarness.Id id;

    // Assume the market is created.
    require isCreated(id);
    MoolahHarness.MarketParams itmpBefore = idToMarketParams_(id);

    f(e, args);

    MoolahHarness.MarketParams itmpAfter = idToMarketParams_(id);
    assert itmpBefore == itmpAfter;
}

rule nonceCannotDecrease(method f, env e, calldataarg args) filtered { f -> !f.isView && !isExcludedOp(f) } {
    address user;

    uint256 nonceBefore = nonce(user);

    f(e, args);

    uint256 nonceAfter = nonce(user);
    assert(nonceAfter == nonceBefore || nonceAfter == nonceBefore + 1);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { FixedLoanPosition } from "../../src/broker/interfaces/IBroker.sol";
import { UtilsLib } from "../../src/moolah/libraries/UtilsLib.sol";

/// @title Tests for BrokerMath.deductFixedPositionDebt
/// @notice Validates that partial liquidation preserves exact outstanding interest,
///         accounting for the reduced principal effect on the interest formula.
contract BrokerMathDeductFixedTest is Test {
  uint256 constant DURATION = 365 days;
  // 10% APR -> RATE_SCALE * 1.10
  uint256 constant APR = 110 * 1e25;

  uint256 startTs;

  function setUp() public {
    vm.warp(1_000_000);
    startTs = block.timestamp;
  }

  function _makePosition(uint256 principal) internal view returns (FixedLoanPosition memory) {
    return
      FixedLoanPosition({
        posId: 1,
        principal: principal,
        apr: APR,
        start: startTs,
        end: startTs + DURATION,
        lastRepaidTime: startTs,
        interestRepaid: 0,
        principalRepaid: 0
      });
  }

  /// @dev Helper: compute outstanding interest for a position
  function _outstanding(FixedLoanPosition memory p) internal view returns (uint256) {
    return BrokerMath.getAccruedInterestForFixedPosition(p) - p.interestRepaid;
  }

  // ====================================================================
  //  Core fix: partial liquidation preserves EXACT outstanding interest
  // ====================================================================

  /// @notice principal=100e18, interest~10e18, liquidation pays half interest + half principal.
  ///         Outstanding interest must be exactly (accruedInterest - paidInterest).
  function test_partialLiquidation_preservesExactOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    assertApproxEqRel(accruedInterest, 10 ether, 1e15, "accrued ~10 ether");

    uint256 interestBudget = accruedInterest / 2;
    uint256 principalBudget = 50 ether;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, principalBudget, pos);

    // Budgets fully consumed
    assertEq(interestLeft, 0, "interest budget consumed");
    assertEq(principalLeft, 0, "principal budget consumed");
    assertEq(updated.principalRepaid, principalBudget, "principalRepaid correct");

    // Core invariant: outstanding = accruedInterest - paidInterest (exact)
    uint256 expectedOutstanding = accruedInterest - interestBudget;
    uint256 actualOutstanding = _outstanding(updated);
    assertEq(actualOutstanding, expectedOutstanding, "outstanding interest must be exact");
  }

  // ====================================================================
  //  Full interest payment resets correctly
  // ====================================================================

  function test_fullInterestPayment_resetsTracking() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(accruedInterest, 30 ether, pos);

    assertEq(updated.interestRepaid, 0, "interestRepaid resets when all interest paid");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime resets to now");
    assertEq(updated.principalRepaid, 30 ether, "principalRepaid correct");

    // Outstanding should be 0 after full interest payment
    assertEq(_outstanding(updated), 0, "no outstanding interest after full payment");
  }

  // ====================================================================
  //  Interest only, no principal deduction
  // ====================================================================

  function test_interestOnlyPartial_preservesOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 3;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, 0, pos);

    assertEq(interestLeft, 0, "interest budget consumed");
    assertEq(principalLeft, 0, "no principal to deduct");
    assertEq(updated.interestRepaid, interestBudget, "partial interest tracked");
    assertEq(updated.lastRepaidTime, startTs, "lastRepaidTime unchanged");

    uint256 expectedOutstanding = accruedInterest - interestBudget;
    assertEq(_outstanding(updated), expectedOutstanding, "outstanding exact for interest-only");
  }

  // ====================================================================
  //  Full principal with partial interest -> fallback (position filtered out)
  // ====================================================================

  function test_fullPrincipalPartialInterest_capsRepayment() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 4;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, 100 ether, pos);

    assertEq(interestLeft, 0, "interest budget consumed");
    // With 25% interest paid, roughly 25% of principal can be safely repaid
    uint256 principalRepaid = 100 ether - principalLeft;
    assertGt(principalRepaid, 0, "some principal repaid");
    assertLt(principalRepaid, 100 ether, "not all principal repaid");

    // Outstanding interest preserved
    uint256 unpaidInterest = accruedInterest - interestBudget;
    assertGe(_outstanding(updated), unpaidInterest, "unpaid interest preserved");
  }

  // ====================================================================
  //  Zero interest accrued (immediate liquidation)
  // ====================================================================

  function test_zeroInterest_principalOnly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    // No time skip -> zero interest

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(10 ether, 50 ether, pos);

    assertEq(interestLeft, 10 ether, "interest budget returned unused");
    assertEq(principalLeft, 0, "principal budget consumed");
    assertEq(updated.principalRepaid, 50 ether, "principal repaid");
    // 0 >= 0 -> reset happens (correct, no interest to lose)
    assertEq(updated.interestRepaid, 0, "no interest to track");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset fine when no interest");
  }

  // ====================================================================
  //  Sequential partial liquidations preserve cumulative outstanding
  // ====================================================================

  function test_sequentialPartialLiquidations_preserveOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 originalAccrued = _outstanding(pos);

    // First partial: 1/4 interest + 20 principal
    uint256 firstInterest = originalAccrued / 4;
    (, , FixedLoanPosition memory after1) = BrokerMath.deductFixedPositionDebt(firstInterest, 20 ether, pos);

    uint256 expectedAfter1 = originalAccrued - firstInterest;
    assertEq(_outstanding(after1), expectedAfter1, "first: outstanding exact");
    assertEq(after1.principalRepaid, 20 ether, "first: principal tracked");

    // Second partial: another chunk of interest + 30 principal
    uint256 outstandingAfter1 = _outstanding(after1);
    uint256 secondInterest = outstandingAfter1 / 3;

    (, , FixedLoanPosition memory after2) = BrokerMath.deductFixedPositionDebt(secondInterest, 30 ether, after1);

    uint256 expectedAfter2 = outstandingAfter1 - secondInterest;
    // allow tolerance due to Ceil rounding + lastRepaidTime adjustment in interest formula
    assertApproxEqRel(_outstanding(after2), expectedAfter2, 1e15, "second: outstanding approx");
    // With capping, cumulative principal may be slightly less due to floor rounding in cap
    assertApproxEqRel(after2.principalRepaid, 50 ether, 1e15, "second: cumulative principal approx");

    // Outstanding still positive
    assertGt(_outstanding(after2), 0, "interest still outstanding");
  }

  // ====================================================================
  //  Over-payment: budget exceeds debt
  // ====================================================================

  function test_overPayment_cappedCorrectly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(accruedInterest * 10, 500 ether, pos);

    assertApproxEqAbs(interestLeft, accruedInterest * 9, 1e15, "excess interest returned");
    assertEq(principalLeft, 400 ether, "excess principal returned");
    assertEq(updated.principalRepaid, 100 ether, "full principal repaid");
    // All interest paid -> reset
    assertEq(updated.interestRepaid, 0, "reset after full interest payment");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset lastRepaidTime");
  }

  // ====================================================================
  //  Exact interest match triggers reset
  // ====================================================================

  function test_exactInterestMatch_triggersReset() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(accruedInterest, 40 ether, pos);

    assertEq(updated.interestRepaid, 0, "reset on exact match");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset time on exact match");
    assertEq(updated.principalRepaid, 40 ether, "principal deducted");
    assertEq(_outstanding(updated), 0, "no outstanding after exact match");
  }

  // ====================================================================
  //  1 wei short of full interest -> no reset, exact outstanding
  // ====================================================================

  function test_oneWeiShort_preservesExactOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    require(accruedInterest > 1, "need non-trivial interest");

    uint256 interestBudget = accruedInterest - 1;

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(interestBudget, 50 ether, pos);

    // 1 wei unpaid -> must preserve exactly
    assertEq(_outstanding(updated), 1, "exactly 1 wei outstanding preserved");
  }

  // ====================================================================
  //  Zero interest budget with principal deduction -> principal capped
  // ====================================================================

  function test_zeroInterestBudget_principalOnly_capsRepayment() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    assertGt(accruedInterest, 0, "should have accrued interest");

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(0, 50 ether, pos);

    assertEq(interestLeft, 0, "no interest budget to return");
    // No interest was paid -> oldTotalAccrued <= unpaidInterest -> no principal can be safely repaid
    // So principalLeft should return the full 50 ether
    assertEq(principalLeft, 50 ether, "principal returned as leftover");
    assertEq(updated.principalRepaid, 0, "no principal repaid");
    // Outstanding interest fully preserved
    assertEq(_outstanding(updated), accruedInterest, "full outstanding preserved");
  }

  // ====================================================================
  //  Small principal + large interest -> fallback maximizes preserved
  // ====================================================================

  function test_smallPrincipal_largeInterest_capsAndPreservesOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    // Tiny interest budget + small principal
    uint256 interestBudget = 1;
    uint256 principalBudget = 5 ether;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, principalBudget, pos);

    uint256 unpaidInterest = accruedInterest - interestBudget;
    assertEq(interestLeft, 0, "interest budget consumed");
    // Principal repayment is capped: only a fraction of 5 ether can be repaid safely
    // maxSafe = 100e18 * (oldTotalAccrued - unpaidInterest) / oldTotalAccrued
    //         = 100e18 * 1 / oldTotalAccrued ≈ 0 (very small)
    assertGt(principalLeft, 0, "some principal returned as leftover");
    // Outstanding interest fully preserved
    assertGe(_outstanding(updated), unpaidInterest, "unpaid interest fully preserved");
  }

  // ====================================================================
  //  Edge case: near-full principal repay with tiny interest payment
  // ====================================================================

  /// @notice Repay 99/100 ether principal with 1 wei interest.
  ///         Principal repayment is capped to preserve unpaid interest.
  function test_edgeCase_nearFullPrincipalRepay_capsToPreserveInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = 1; // 1 wei
    uint256 principalBudget = 99 ether;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, principalBudget, pos);

    assertEq(interestLeft, 0, "interest budget consumed");
    uint256 unpaidInterest = accruedInterest - interestBudget;
    // Principal repayment is capped -> most of the 99 ether is returned as leftover
    assertGt(principalLeft, 0, "excess principal returned");
    // Core assertion: outstanding interest must be >= unpaidInterest (not forgiven)
    assertGe(_outstanding(updated), unpaidInterest, "unpaid interest fully preserved");
  }

  // ====================================================================
  //  Edge case: partial interest allows proportional principal repayment
  // ====================================================================

  /// @notice When half the interest is paid, roughly half the principal can be safely repaid.
  function test_edgeCase_halfInterestPaid_allowsProportionalPrincipal() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 2;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(interestBudget, 100 ether, pos);

    assertEq(interestLeft, 0, "interest budget consumed");
    // With half interest paid, roughly half the principal can be safely repaid
    uint256 principalRepaid = 100 ether - principalLeft;
    assertGt(principalRepaid, 0, "some principal repaid");
    // Outstanding interest preserved
    uint256 unpaidInterest = accruedInterest - interestBudget;
    assertGe(_outstanding(updated), unpaidInterest, "unpaid interest preserved");
  }

  // ====================================================================
  //  Edge case: zero interest budget -> no principal can be repaid
  // ====================================================================

  /// @notice When no interest is paid at all, no principal should be repaid
  ///         because any reduction would lose interest tracking.
  function test_edgeCase_zeroInterestBudget_noPrincipalRepaid() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    (, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(
      0,
      99.9 ether,
      pos
    );

    // No interest paid -> oldTotalAccrued == unpaidInterest -> maxSafePrincipalRepay = 0
    assertEq(principalLeft, 99.9 ether, "all principal returned");
    assertEq(updated.principalRepaid, 0, "no principal repaid");
    assertEq(_outstanding(updated), accruedInterest, "outstanding unchanged");
  }

  // ====================================================================
  //  After reset, new interest accrues correctly
  // ====================================================================

  function test_resetThenNewAccrual_worksCorrectly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION / 2);

    uint256 accrued1 = _outstanding(pos);

    // Pay all interest + 20 principal -> triggers reset
    (, , FixedLoanPosition memory after1) = BrokerMath.deductFixedPositionDebt(accrued1, 20 ether, pos);

    assertEq(after1.interestRepaid, 0, "reset after full interest");
    assertEq(after1.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(_outstanding(after1), 0, "no outstanding after reset");

    // More time passes -> new interest accrues on reduced principal
    skip(DURATION / 2);

    uint256 accrued2 = _outstanding(after1);
    assertGt(accrued2, 0, "new interest accrued after reset");

    // Partial interest + 30 principal -> should NOT reset, preserve exact
    uint256 partialInterest = accrued2 / 2;
    (, , FixedLoanPosition memory after2) = BrokerMath.deductFixedPositionDebt(partialInterest, 30 ether, after1);

    uint256 expectedOutstanding = accrued2 - partialInterest;
    assertEq(_outstanding(after2), expectedOutstanding, "exact after second partial");
    assertEq(after2.principalRepaid, 50 ether, "cumulative 50 principal");
  }
}

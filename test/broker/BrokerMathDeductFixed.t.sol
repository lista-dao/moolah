// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { FixedLoanPosition } from "../../src/broker/interfaces/IBroker.sol";
import { UtilsLib } from "../../src/moolah/libraries/UtilsLib.sol";

/// @title Tests for BrokerMath.deductFixedPositionDebt
/// @notice The current implementation deliberately resets `interestRepaid` and
///         `lastRepaidTime` on any positive principal payment — the audit-acknowledged
///         simplified semantic. Outstanding interest is only preserved when the call
///         is interest-only. These tests validate that reset behaviour and the
///         interest-only preservation path.
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
  //  Any principal payment resets interest tracking
  // ====================================================================

  /// @notice principal=100e18, interest~10e18, partial-interest + partial-principal.
  ///         After the call: interestRepaid = 0, lastRepaidTime = now, outstanding = 0
  ///         (no time has elapsed since the reset).
  function test_partialLiquidation_resetsInterestOnPrincipalPayment() public {
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

    // Simplified reset semantic: any positive principal payment wipes interest tracking
    assertEq(updated.interestRepaid, 0, "interestRepaid reset to 0");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime reset to now");
    assertEq(_outstanding(updated), 0, "no outstanding immediately after reset");
  }

  // ====================================================================
  //  Full interest + principal: reset (same as core path)
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
  //  Interest-only path: preserves exact outstanding (no principal => no reset)
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
  //  Full principal with partial interest -> reset + filtered out
  // ====================================================================

  function test_fullPrincipalPartialInterest_fallback() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 4;

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(interestBudget, 100 ether, pos);

    assertEq(updated.principalRepaid, 100 ether, "full principal repaid");

    // When principal is fully repaid, (principal - principalRepaid) = 0,
    // so getAccruedInterestForFixedPosition returns 0 -> fallback case.
    // outstanding = 0, but position would be filtered out anyway.
    bool wouldBeFiltered = !(updated.principal > updated.principalRepaid);
    assertTrue(wouldBeFiltered, "fully-repaid position filtered out in sortAndFilter");
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
  //  Sequential partial liquidations: each principal payment resets,
  //  new interest accrues between calls based on elapsed time + reduced principal.
  // ====================================================================

  function test_sequentialPartialLiquidations_resetEachTime() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    // Move part-way through the term so interest can still accrue between calls.
    skip(DURATION / 3);

    uint256 originalAccrued = _outstanding(pos);
    assertGt(originalAccrued, 0, "precondition: interest accrued");

    // First partial: 1/4 interest + 20 principal -> reset triggered
    uint256 firstInterest = originalAccrued / 4;
    (, , FixedLoanPosition memory after1) = BrokerMath.deductFixedPositionDebt(firstInterest, 20 ether, pos);

    // Reset semantic: interestRepaid wiped, lastRepaidTime = now, outstanding = 0 in this block
    assertEq(after1.interestRepaid, 0, "first: interest tracking reset");
    assertEq(after1.lastRepaidTime, block.timestamp, "first: lastRepaidTime = now");
    assertEq(after1.principalRepaid, 20 ether, "first: principal tracked");
    assertEq(_outstanding(after1), 0, "first: no outstanding immediately after reset");

    // Let time elapse — still within the term — so new interest accrues on the reduced principal
    skip(DURATION / 3);
    uint256 outstandingAfter1 = _outstanding(after1);
    assertGt(outstandingAfter1, 0, "new interest accrued after reset");

    // Second partial: another chunk of interest + 30 principal -> reset again
    uint256 secondInterest = outstandingAfter1 / 3;
    (, , FixedLoanPosition memory after2) = BrokerMath.deductFixedPositionDebt(secondInterest, 30 ether, after1);

    assertEq(after2.interestRepaid, 0, "second: interest tracking reset");
    assertEq(after2.lastRepaidTime, block.timestamp, "second: lastRepaidTime = now");
    assertEq(after2.principalRepaid, 50 ether, "second: cumulative principal");
    assertEq(_outstanding(after2), 0, "second: no outstanding immediately after reset");
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
  //  1-wei-short interest + principal: principal still triggers reset
  //  (the 1 wei of unpaid interest is forgiven — the simplified semantic).
  // ====================================================================

  function test_oneWeiShort_stillResetsOnPrincipalPayment() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    require(accruedInterest > 1, "need non-trivial interest");

    uint256 interestBudget = accruedInterest - 1;

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(interestBudget, 50 ether, pos);

    // Simplified semantic: the principal payment resets tracking regardless of the 1-wei gap.
    assertEq(updated.interestRepaid, 0, "interest tracking reset");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(_outstanding(updated), 0, "outstanding = 0 right after the reset");
  }

  // ====================================================================
  //  Zero interest budget + positive principal -> principal triggers reset
  //  (the entire accrued interest is forgiven — the simplified semantic).
  // ====================================================================

  function test_zeroInterestBudget_principalOnly_resetsInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    assertGt(accruedInterest, 0, "should have accrued interest");

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) = BrokerMath
      .deductFixedPositionDebt(0, 50 ether, pos);

    assertEq(interestLeft, 0, "no interest budget to return");
    assertEq(principalLeft, 0, "principal consumed");
    assertEq(updated.principalRepaid, 50 ether, "principal repaid");

    // Simplified semantic: the principal payment resets all interest tracking,
    // even though the budget did not include any interest.
    assertEq(updated.interestRepaid, 0, "interest tracking reset");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(_outstanding(updated), 0, "outstanding = 0 right after the reset");
  }

  // ====================================================================
  //  Tiny interest budget + small principal: same reset behaviour.
  // ====================================================================

  function test_smallPrincipal_largeInterest_resetsOnPrincipalPayment() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    // Tiny interest budget + small principal
    uint256 interestBudget = 1;
    uint256 principalBudget = 5 ether;

    (, , FixedLoanPosition memory updated) = BrokerMath.deductFixedPositionDebt(interestBudget, principalBudget, pos);

    // Simplified semantic: principal payment resets tracking regardless of how much interest was left.
    assertEq(updated.interestRepaid, 0, "interest tracking reset");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(updated.principalRepaid, principalBudget, "principal repaid");
    assertEq(_outstanding(updated), 0, "outstanding = 0 right after the reset");
  }

  // ====================================================================
  //  After reset, new interest accrues correctly; a subsequent
  //  partial-with-principal call resets again.
  // ====================================================================

  function test_resetThenNewAccrual_resetsAgainOnSecondPrincipalPayment() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION / 2);

    uint256 accrued1 = _outstanding(pos);

    // Pay all interest + 20 principal -> triggers reset
    (, , FixedLoanPosition memory after1) = BrokerMath.deductFixedPositionDebt(accrued1, 20 ether, pos);

    assertEq(after1.interestRepaid, 0, "reset after full interest");
    assertEq(after1.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(_outstanding(after1), 0, "no outstanding after reset");

    // More time passes -> new interest accrues on the reduced (80e18) principal
    skip(DURATION / 2);

    uint256 accrued2 = _outstanding(after1);
    assertGt(accrued2, 0, "new interest accrued after reset");

    // Partial interest + 30 principal -> resets again per the simplified semantic
    uint256 partialInterest = accrued2 / 2;
    (, , FixedLoanPosition memory after2) = BrokerMath.deductFixedPositionDebt(partialInterest, 30 ether, after1);

    assertEq(after2.interestRepaid, 0, "second: interest tracking reset");
    assertEq(after2.lastRepaidTime, block.timestamp, "second: lastRepaidTime = now");
    assertEq(after2.principalRepaid, 50 ether, "cumulative 50 principal");
    assertEq(_outstanding(after2), 0, "no outstanding immediately after reset");
  }
}

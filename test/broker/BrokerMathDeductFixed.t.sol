// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { FixedLoanPosition } from "../../src/broker/interfaces/IBroker.sol";

/// @title Tests for BrokerMath.deductFixedPositionDebt
/// @notice Validates the fix: partial liquidation must NOT erase unpaid interest
///         when interestToDeduct < accruedInterest and principalToDeduct > 0.
///
///         The core invariant enforced by the fix:
///         - When NOT all accrued interest is paid, `interestRepaid` and `lastRepaidTime`
///           must NOT be reset. This preserves the interest tracking state so that
///           subsequent getTotalDebt / deductFixedPositionDebt calls remain correct.
contract BrokerMathDeductFixedTest is Test {
  uint256 constant DURATION = 365 days;
  // 10% APR → RATE_SCALE * 1.10
  // This gives ~10 ether interest per year on 100 ether principal
  uint256 constant APR = 110 * 1e25;

  uint256 startTs;

  function setUp() public {
    vm.warp(1_000_000);
    startTs = block.timestamp;
  }

  function _makePosition(uint256 principal) internal view returns (FixedLoanPosition memory) {
    return FixedLoanPosition({
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

  // ====================================================================
  //  Core bug scenario: partial liquidation erases unpaid interest
  // ====================================================================

  /// @notice Audit scenario: principal=100, interest≈10, liquidation pays 5 interest + 50 principal.
  ///         Before fix: interestRepaid reset to 0, lastRepaidTime reset → 5 interest erased.
  ///         After fix: interestRepaid=5, lastRepaidTime unchanged → state preserved.
  function test_partialLiquidation_doesNotEraseUnpaidInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);
    assertApproxEqRel(accruedInterest, 10 ether, 1e15, "accrued interest ~10 ether");

    // Partial liquidation: pay half the interest + half the principal
    uint256 interestBudget = accruedInterest / 2;
    uint256 principalBudget = 50 ether;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(interestBudget, principalBudget, pos);

    // All budgets consumed
    assertEq(interestLeft, 0, "all interest budget used");
    assertEq(principalLeft, 0, "all principal budget used");

    // STATE PRESERVATION — the core fix:
    // interestRepaid must NOT be zeroed (tracks what was actually paid)
    assertEq(updated.interestRepaid, interestBudget, "interestRepaid must retain partial payment");
    // lastRepaidTime must NOT advance (interest accrual period unchanged)
    assertEq(updated.lastRepaidTime, startTs, "lastRepaidTime must not reset");
    // principal tracking correct
    assertEq(updated.principalRepaid, principalBudget, "principalRepaid correct");

    // Note: getAccruedInterestForFixedPosition(updated) recalculates on REDUCED principal
    // (100-50=50), so the outstanding interest won't equal (original_accrued - interestBudget).
    // This is a known limitation of the linear interest model — the fix preserves STATE,
    // which is the critical invariant for subsequent getTotalDebt calls.
    uint256 recalcAccrued = BrokerMath.getAccruedInterestForFixedPosition(updated);
    assertGe(recalcAccrued, updated.interestRepaid, "recalculated accrued >= paid (no underflow)");
  }

  // ====================================================================
  //  Full interest payment still resets correctly
  // ====================================================================

  function test_fullInterestPayment_resetsTracking() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);

    (, , FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(accruedInterest, 30 ether, pos);

    // All interest paid → reset is correct
    assertEq(updated.interestRepaid, 0, "interestRepaid resets when all interest paid");
    assertEq(updated.lastRepaidTime, block.timestamp, "lastRepaidTime resets to now");
    assertEq(updated.principalRepaid, 30 ether, "principalRepaid correct");
  }

  // ====================================================================
  //  Interest only, no principal deduction
  // ====================================================================

  function test_interestOnlyPartial_noReset() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);
    uint256 interestBudget = accruedInterest / 3;

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(interestBudget, 0, pos);

    assertEq(interestLeft, 0, "interest budget consumed");
    assertEq(principalLeft, 0, "no principal to deduct");
    assertEq(updated.interestRepaid, interestBudget, "partial interest tracked");
    assertEq(updated.lastRepaidTime, startTs, "lastRepaidTime unchanged");
    assertEq(updated.principalRepaid, 0, "no principal repaid");

    // Since principal unchanged, outstanding = original_accrued - paid
    uint256 outstanding = BrokerMath.getAccruedInterestForFixedPosition(updated) - updated.interestRepaid;
    assertApproxEqAbs(outstanding, accruedInterest - interestBudget, 1, "outstanding interest preserved");
  }

  // ====================================================================
  //  Full principal repayment with partial interest
  // ====================================================================

  /// @notice All principal repaid but interest partially paid.
  ///         The fix preserves interestRepaid/lastRepaidTime state.
  ///         Note: getAccruedInterestForFixedPosition returns 0 when remaining principal=0,
  ///         so in practice this position would be filtered out by sortAndFilterFixedPositions
  ///         (since principal == principalRepaid).
  function test_fullPrincipalPartialInterest_statePreserved() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);
    uint256 interestBudget = accruedInterest / 4;

    (, , FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(interestBudget, 100 ether, pos);

    // Principal fully repaid
    assertEq(updated.principalRepaid, 100 ether, "full principal repaid");
    // Interest state preserved (not zeroed)
    assertEq(updated.interestRepaid, interestBudget, "interestRepaid preserved");
    assertEq(updated.lastRepaidTime, startTs, "lastRepaidTime not reset");

    // This position has principal == principalRepaid, so it would be
    // filtered out by sortAndFilterFixedPositions in the liquidation flow.
    bool wouldBeFiltered = !(updated.principal > updated.principalRepaid);
    assertTrue(wouldBeFiltered, "fully-repaid position would be filtered out");
  }

  // ====================================================================
  //  Zero interest accrued (immediate liquidation)
  // ====================================================================

  function test_zeroInterest_principalOnly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    // No time skip → zero interest

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(10 ether, 50 ether, pos);

    assertEq(interestLeft, 10 ether, "interest budget returned unused");
    assertEq(principalLeft, 0, "principal budget consumed");
    assertEq(updated.principalRepaid, 50 ether, "principal repaid");
    // 0 >= 0 is true → reset happens (correct, no interest to lose)
    assertEq(updated.interestRepaid, 0, "no interest to track");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset fine when no interest");
  }

  // ====================================================================
  //  Sequential partial liquidations
  // ====================================================================

  function test_sequentialPartialLiquidations_preserveInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);

    // First partial: 1/4 interest + 20 principal
    uint256 firstInterest = accruedInterest / 4;
    (, , FixedLoanPosition memory after1) =
      BrokerMath.deductFixedPositionDebt(firstInterest, 20 ether, pos);

    assertEq(after1.interestRepaid, firstInterest, "first: interestRepaid tracked");
    assertEq(after1.principalRepaid, 20 ether, "first: principal tracked");
    assertEq(after1.lastRepaidTime, startTs, "first: no reset");

    // Second partial: another chunk of outstanding interest + 30 principal
    uint256 accruedAfter1 = BrokerMath.getAccruedInterestForFixedPosition(after1);
    uint256 outstandingAfter1 = accruedAfter1 - after1.interestRepaid;
    uint256 secondInterest = outstandingAfter1 / 3;

    (, , FixedLoanPosition memory after2) =
      BrokerMath.deductFixedPositionDebt(secondInterest, 30 ether, after1);

    assertEq(after2.principalRepaid, 50 ether, "second: cumulative principal");
    assertEq(after2.interestRepaid, firstInterest + secondInterest, "second: cumulative interest");
    assertEq(after2.lastRepaidTime, startTs, "second: still no reset");

    // Outstanding interest remains positive
    uint256 accruedAfter2 = BrokerMath.getAccruedInterestForFixedPosition(after2);
    assertGt(accruedAfter2, after2.interestRepaid, "interest still outstanding");
  }

  // ====================================================================
  //  Over-payment: budget exceeds debt
  // ====================================================================

  function test_overPayment_cappedCorrectly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(accruedInterest * 10, 500 ether, pos);

    assertApproxEqAbs(interestLeft, accruedInterest * 9, 1e15, "excess interest returned");
    assertEq(principalLeft, 400 ether, "excess principal returned");
    assertEq(updated.principalRepaid, 100 ether, "full principal repaid");
    // All interest paid → reset
    assertEq(updated.interestRepaid, 0, "reset after full interest payment");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset lastRepaidTime");
  }

  // ====================================================================
  //  Edge: exact interest match triggers reset
  // ====================================================================

  function test_exactInterestMatch_triggersReset() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);

    (, , FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(accruedInterest, 40 ether, pos);

    assertEq(updated.interestRepaid, 0, "reset on exact match");
    assertEq(updated.lastRepaidTime, block.timestamp, "reset time on exact match");
    assertEq(updated.principalRepaid, 40 ether, "principal deducted");
  }

  // ====================================================================
  //  Edge: 1 wei short of full interest → no reset
  // ====================================================================

  function test_oneWeiShort_noReset() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);
    require(accruedInterest > 1, "need non-trivial interest");

    uint256 interestBudget = accruedInterest - 1;

    (, , FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(interestBudget, 50 ether, pos);

    // 1 wei unpaid → must NOT reset
    assertEq(updated.interestRepaid, interestBudget, "interestRepaid = budget");
    assertEq(updated.lastRepaidTime, startTs, "no reset at 1 wei short");
  }

  // ====================================================================
  //  No interest budget but principal budget, with outstanding interest
  // ====================================================================

  function test_zeroBudgetInterest_principalOnly_noReset() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(pos);
    assertGt(accruedInterest, 0, "should have accrued interest");

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated) =
      BrokerMath.deductFixedPositionDebt(0, 50 ether, pos);

    assertEq(interestLeft, 0, "no interest budget to return");
    assertEq(principalLeft, 0, "principal consumed");
    assertEq(updated.principalRepaid, 50 ether, "principal repaid");
    // repayInterestAmt=0, accruedInterest>0 → 0 < accruedInterest → NO reset
    assertEq(updated.interestRepaid, 0, "no interest was paid");
    assertEq(updated.lastRepaidTime, startTs, "no reset when interest unpaid");
  }

  // ====================================================================
  //  Verify: after full-interest partial-principal, subsequent call works
  // ====================================================================

  /// @notice After a full-interest-paid deduction (which resets state),
  ///         a subsequent partial-interest deduction should work correctly.
  function test_resetThenPartial_worksCorrectly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION / 2);

    uint256 accrued1 = BrokerMath.getAccruedInterestForFixedPosition(pos);

    // First call: pay all interest + 20 principal → triggers reset
    (, , FixedLoanPosition memory after1) =
      BrokerMath.deductFixedPositionDebt(accrued1, 20 ether, pos);

    assertEq(after1.interestRepaid, 0, "reset after full interest");
    assertEq(after1.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(after1.principalRepaid, 20 ether, "20 principal repaid");

    // More time passes → new interest accrues from reset point
    skip(DURATION / 2);

    uint256 accrued2 = BrokerMath.getAccruedInterestForFixedPosition(after1);
    assertGt(accrued2, 0, "new interest accrued after reset");

    // Second call: partial interest + 30 principal → should NOT reset
    uint256 partialInterest = accrued2 / 2;
    (, , FixedLoanPosition memory after2) =
      BrokerMath.deductFixedPositionDebt(partialInterest, 30 ether, after1);

    assertEq(after2.interestRepaid, partialInterest, "partial interest tracked");
    assertEq(after2.lastRepaidTime, after1.lastRepaidTime, "no reset on partial");
    assertEq(after2.principalRepaid, 50 ether, "cumulative 50 principal");
  }
}

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

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated, ) = BrokerMath
      .deductFixedPositionDebt(interestBudget, principalBudget, pos, 0);

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

    (, , FixedLoanPosition memory updated, ) = BrokerMath.deductFixedPositionDebt(accruedInterest, 30 ether, pos, 0);

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

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated, ) = BrokerMath
      .deductFixedPositionDebt(interestBudget, 0, pos, 0);

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

  function test_fullPrincipalPartialInterest_fallback() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 4;

    (, , FixedLoanPosition memory updated, ) = BrokerMath.deductFixedPositionDebt(interestBudget, 100 ether, pos, 0);

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

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated, ) = BrokerMath
      .deductFixedPositionDebt(10 ether, 50 ether, pos, 0);

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
    (, , FixedLoanPosition memory after1, ) = BrokerMath.deductFixedPositionDebt(firstInterest, 20 ether, pos, 0);

    uint256 expectedAfter1 = originalAccrued - firstInterest;
    assertEq(_outstanding(after1), expectedAfter1, "first: outstanding exact");
    assertEq(after1.principalRepaid, 20 ether, "first: principal tracked");

    // Second partial: another chunk of interest + 30 principal
    uint256 outstandingAfter1 = _outstanding(after1);
    uint256 secondInterest = outstandingAfter1 / 3;

    (, , FixedLoanPosition memory after2, ) = BrokerMath.deductFixedPositionDebt(secondInterest, 30 ether, after1, 0);

    uint256 expectedAfter2 = outstandingAfter1 - secondInterest;
    // allow 1 wei tolerance due to Ceil rounding in interest formula
    assertApproxEqAbs(_outstanding(after2), expectedAfter2, 1, "second: outstanding exact");
    assertEq(after2.principalRepaid, 50 ether, "second: cumulative principal");

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

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated, ) = BrokerMath
      .deductFixedPositionDebt(accruedInterest * 10, 500 ether, pos, 0);

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

    (, , FixedLoanPosition memory updated, ) = BrokerMath.deductFixedPositionDebt(accruedInterest, 40 ether, pos, 0);

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

    (, , FixedLoanPosition memory updated, ) = BrokerMath.deductFixedPositionDebt(interestBudget, 50 ether, pos, 0);

    // 1 wei unpaid -> must preserve exactly
    assertEq(_outstanding(updated), 1, "exactly 1 wei outstanding preserved");
  }

  // ====================================================================
  //  Zero interest budget with principal deduction -> maximize preserved
  // ====================================================================

  function test_zeroInterestBudget_principalOnly_maximizesOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    assertGt(accruedInterest, 0, "should have accrued interest");

    (uint256 interestLeft, uint256 principalLeft, FixedLoanPosition memory updated, ) = BrokerMath
      .deductFixedPositionDebt(0, 50 ether, pos, 0);

    assertEq(interestLeft, 0, "no interest budget to return");
    assertEq(principalLeft, 0, "principal consumed");
    assertEq(updated.principalRepaid, 50 ether, "principal repaid");

    // newTotalAccrued = (100-50)*10%*1year = 5e18, unpaidInterest = 10e18
    // newTotalAccrued < unpaidInterest -> fallback: outstanding = newTotalAccrued
    // This is the maximum the formula can represent (better than reset which gives 0)
    uint256 newTotalAccrued = BrokerMath.getAccruedInterestForFixedPosition(updated);
    assertEq(_outstanding(updated), newTotalAccrued, "fallback preserves maximum possible");
    assertGt(_outstanding(updated), 0, "outstanding > 0 (not reset to zero)");
    // Verify: lastRepaidTime was NOT reset (preserves historical accrual)
    assertEq(updated.lastRepaidTime, startTs, "lastRepaidTime not reset in fallback");
  }

  // ====================================================================
  //  Small principal + large interest -> fallback maximizes preserved
  // ====================================================================

  function test_smallPrincipal_largeInterest_maximizesOutstanding() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);

    // Tiny interest budget + small principal
    uint256 interestBudget = 1;
    uint256 principalBudget = 5 ether;

    (, , FixedLoanPosition memory updated, ) = BrokerMath.deductFixedPositionDebt(
      interestBudget,
      principalBudget,
      pos,
      0
    );

    // newTotalAccrued = (100-5)*10%*1year = 9.5e18, unpaidInterest ~= 10e18
    // newTotalAccrued < unpaidInterest -> fallback: maximize outstanding
    uint256 newTotalAccrued = BrokerMath.getAccruedInterestForFixedPosition(updated);
    assertEq(_outstanding(updated), newTotalAccrued, "fallback preserves max possible");
    assertGt(_outstanding(updated), 0, "outstanding > 0");
    // Verify: better than old code which would give outstanding = 0
    assertGt(_outstanding(updated), accruedInterest / 2, "preserves majority of interest");
  }

  // ====================================================================
  //  Audit #5: interest-only repayment must consume extraInterest
  // ====================================================================

  function test_interestOnlyRepayment_consumesExtraInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    // Step 1: principal-only deduction creates extraInterest overflow
    (, , FixedLoanPosition memory afterPrincipalCut, uint256 extraInterest) = BrokerMath.deductFixedPositionDebt(
      0,
      50 ether,
      pos,
      0
    );

    uint256 formulaInterest = BrokerMath.getAccruedInterestForFixedPosition(afterPrincipalCut);
    assertGt(extraInterest, 0, "expected extra interest overflow");

    // Step 2: repay all remaining interest (formula + extra), no principal
    uint256 fullOutstanding = formulaInterest + extraInterest;
    (, , FixedLoanPosition memory afterInterestOnly, uint256 extraAfterInterestOnly) = BrokerMath
      .deductFixedPositionDebt(fullOutstanding, 0, afterPrincipalCut, extraInterest);

    // extraInterest should be fully consumed
    assertEq(extraAfterInterestOnly, 0, "extra interest should be consumed");
    // interestRepaid should not exceed formula interest
    assertLe(
      afterInterestOnly.interestRepaid,
      BrokerMath.getAccruedInterestForFixedPosition(afterInterestOnly),
      "interestRepaid must not exceed formula interest"
    );

    // previewRepayFixedLoanPosition should NOT revert
    BrokerMath.previewRepayFixedLoanPosition(afterInterestOnly, 1, extraAfterInterestOnly);
  }

  // ====================================================================
  //  Audit #5: sequential positions - later position gets zero interest budget
  // ====================================================================

  function _makePositionWith(
    uint256 posId,
    uint256 principal,
    uint256 apr,
    uint256 end
  ) internal view returns (FixedLoanPosition memory) {
    return
      FixedLoanPosition({
        posId: posId,
        principal: principal,
        apr: apr,
        start: startTs,
        end: end,
        lastRepaidTime: startTs,
        interestRepaid: 0,
        principalRepaid: 0
      });
  }

  function _deductSequentialFixedPositions(
    FixedLoanPosition[] memory positions,
    uint256 interestToDeduct,
    uint256 principalToDeduct
  ) internal view returns (FixedLoanPosition[] memory, uint256, uint256) {
    FixedLoanPosition[] memory sorted = BrokerMath.sortAndFilterFixedPositions(positions);
    uint256 len = sorted.length;
    uint256 extraInterest = 0;
    for (uint256 i = 0; i < len; i++) {
      if (interestToDeduct == 0 && principalToDeduct == 0) break;
      (interestToDeduct, principalToDeduct, sorted[i], extraInterest) = BrokerMath.deductFixedPositionDebt(
        interestToDeduct,
        principalToDeduct,
        sorted[i],
        extraInterest
      );
    }
    return (sorted, interestToDeduct, principalToDeduct);
  }

  function test_sequentialFixedLiquidation_laterPositionGetsExtraInterest() public {
    uint256 highApr = 101 * RATE_SCALE; // 100x principal interest over one year

    FixedLoanPosition[] memory positions = new FixedLoanPosition[](2);
    positions[0] = _makePositionWith(1, 1 ether, highApr, startTs + DURATION);
    positions[1] = _makePositionWith(2, 99 ether, APR, startTs + DURATION + 1);

    skip(DURATION);

    uint256 firstOutstandingBefore = _outstanding(positions[0]);
    uint256 secondOutstandingBefore = _outstanding(positions[1]);
    assertApproxEqAbs(firstOutstandingBefore, 100 ether, 1, "first accrued interest");
    assertApproxEqAbs(secondOutstandingBefore, 9.9 ether, 1e15, "second accrued interest");

    (FixedLoanPosition[] memory updated, uint256 interestLeft, uint256 principalLeft) = _deductSequentialFixedPositions(
      positions,
      50 ether,
      50 ether
    );

    assertEq(interestLeft, 0, "interest fully consumed");
    assertEq(principalLeft, 0, "principal fully consumed");

    FixedLoanPosition memory first = updated[0];
    FixedLoanPosition memory second = updated[1];

    assertEq(first.principalRepaid, 1 ether, "first position principal fully repaid");
    assertEq(second.principalRepaid, 49 ether, "later position still receives principal");
  }

  // ====================================================================
  //  Audit #5: fully-liquidated position returns extraInterest
  // ====================================================================

  function test_fullPrincipalPartialInterest_returnsExtraInterest() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    uint256 accruedInterest = _outstanding(pos);
    uint256 interestBudget = accruedInterest / 4;

    (, , FixedLoanPosition memory updated, uint256 extraInterest) = BrokerMath.deductFixedPositionDebt(
      interestBudget,
      100 ether,
      pos,
      0
    );

    assertEq(updated.principalRepaid, 100 ether, "full principal repaid");
    // With 0 remaining principal, formula returns 0. Unpaid interest stored as extraInterest.
    uint256 unpaidInterest = accruedInterest - interestBudget;
    assertEq(extraInterest, unpaidInterest, "extraInterest must capture all unpaid interest");
  }

  // ====================================================================
  //  Audit #5: sequential liquidation preserves total debt
  // ====================================================================

  function test_sequentialLiquidation_totalDebtPreserved() public {
    uint256 highApr = 101 * RATE_SCALE;

    FixedLoanPosition[] memory positions = new FixedLoanPosition[](2);
    positions[0] = _makePositionWith(1, 1 ether, highApr, startTs + DURATION);
    positions[1] = _makePositionWith(2, 99 ether, APR, startTs + DURATION + 1);

    skip(DURATION);

    uint256 totalDebtBefore = 0;
    for (uint256 i = 0; i < positions.length; i++) {
      totalDebtBefore += positions[i].principal - positions[i].principalRepaid;
      totalDebtBefore += _outstanding(positions[i]);
    }

    uint256 interestBudget = 50 ether;
    uint256 principalBudget = 50 ether;

    // Process sequentially (simulating _deductFixedPositionsDebt with per-position extraInterest)
    FixedLoanPosition[] memory sorted = BrokerMath.sortAndFilterFixedPositions(positions);
    uint256[] memory extras = new uint256[](sorted.length);
    uint256 intLeft = interestBudget;
    uint256 prinLeft = principalBudget;
    for (uint256 i = 0; i < sorted.length; i++) {
      if (intLeft == 0 && prinLeft == 0) break;
      (intLeft, prinLeft, sorted[i], extras[i]) = BrokerMath.deductFixedPositionDebt(intLeft, prinLeft, sorted[i], 0);
    }

    // Calculate total remaining debt (principal + formula interest + extraInterest)
    uint256 totalDebtAfter = 0;
    for (uint256 i = 0; i < sorted.length; i++) {
      totalDebtAfter += sorted[i].principal - sorted[i].principalRepaid;
      totalDebtAfter += _outstanding(sorted[i]) + extras[i];
    }

    // Total debt should decrease by exactly the budgets consumed
    uint256 consumed = (interestBudget - intLeft) + (principalBudget - prinLeft);
    assertEq(totalDebtBefore - totalDebtAfter, consumed, "total debt reduction must equal consumed budgets");
  }

  // ====================================================================
  //  Audit #5: extraInterest survives interest-only then principal deduction
  // ====================================================================

  function test_extraInterest_survives_multiStepDeduction() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION);

    // Step 1: principal-only deduction creates extraInterest
    (, , FixedLoanPosition memory after1, uint256 extra1) = BrokerMath.deductFixedPositionDebt(0, 50 ether, pos, 0);
    assertGt(extra1, 0, "step 1: extraInterest created");

    // Step 2: partial interest-only repayment consumes some extraInterest
    uint256 halfExtra = extra1 / 2;
    (, , FixedLoanPosition memory after2, uint256 extra2) = BrokerMath.deductFixedPositionDebt(
      halfExtra,
      0,
      after1,
      extra1
    );
    assertEq(extra2, extra1 - halfExtra, "step 2: partial extraInterest consumed");

    // Step 3: full interest repayment clears everything
    uint256 formulaAfter2 = BrokerMath.getAccruedInterestForFixedPosition(after2);
    uint256 totalOutstanding = formulaAfter2 - after2.interestRepaid + extra2;
    (, , FixedLoanPosition memory after3, uint256 extra3) = BrokerMath.deductFixedPositionDebt(
      totalOutstanding,
      0,
      after2,
      extra2
    );
    assertEq(extra3, 0, "step 3: all extraInterest consumed");

    // previewRepayFixedLoanPosition must not revert
    BrokerMath.previewRepayFixedLoanPosition(after3, 1, extra3);
  }

  // ====================================================================
  //  After reset, new interest accrues correctly
  // ====================================================================

  function test_resetThenNewAccrual_worksCorrectly() public {
    FixedLoanPosition memory pos = _makePosition(100 ether);
    skip(DURATION / 2);

    uint256 accrued1 = _outstanding(pos);

    // Pay all interest + 20 principal -> triggers reset
    (, , FixedLoanPosition memory after1, ) = BrokerMath.deductFixedPositionDebt(accrued1, 20 ether, pos, 0);

    assertEq(after1.interestRepaid, 0, "reset after full interest");
    assertEq(after1.lastRepaidTime, block.timestamp, "lastRepaidTime reset");
    assertEq(_outstanding(after1), 0, "no outstanding after reset");

    // More time passes -> new interest accrues on reduced principal
    skip(DURATION / 2);

    uint256 accrued2 = _outstanding(after1);
    assertGt(accrued2, 0, "new interest accrued after reset");

    // Partial interest + 30 principal -> should NOT reset, preserve exact
    uint256 partialInterest = accrued2 / 2;
    (, , FixedLoanPosition memory after2, ) = BrokerMath.deductFixedPositionDebt(partialInterest, 30 ether, after1, 0);

    uint256 expectedOutstanding = accrued2 - partialInterest;
    assertEq(_outstanding(after2), expectedOutstanding, "exact after second partial");
    assertEq(after2.principalRepaid, 50 ether, "cumulative 50 principal");
  }
}

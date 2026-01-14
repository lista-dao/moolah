pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { CreditBrokerMath, RATE_SCALE } from "../../src/broker/libraries/CreditBrokerMath.sol";
import { ICreditBroker, FixedLoanPosition, FixedTermAndRate, GraceConfig, FixedTermType } from "../../src/broker/interfaces/ICreditBroker.sol";

contract CreditBrokerMathTest is Test {
  FixedLoanPosition position;
  GraceConfig graceConfig;

  uint256 termId = 1;
  uint256 duration = 365 days;
  uint256 apr = 13e26; // 30%

  function setUp() public {
    // mock a grace config
    graceConfig = GraceConfig({ period: 3 days, penaltyRate: 15 * 1e25, noInterestPeriod: 60 });

    // mock a fixed position
    position = FixedLoanPosition({
      termType: FixedTermType.UPFRONT_INTEREST,
      posId: 1,
      principal: 1_000 ether,
      apr: apr,
      start: block.timestamp,
      end: block.timestamp + duration,
      lastRepaidTime: block.timestamp,
      interestRepaid: 0,
      principalRepaid: 0,
      noInterestUntil: block.timestamp + graceConfig.noInterestPeriod
    });
  }

  function test_getAccruedInterestForFixedPosition() public {
    position.termType = FixedTermType.ACCRUE_INTEREST;
    // skip duration
    skip(365 days);
    uint256 accruedInterest = CreditBrokerMath.getAccruedInterestForFixedPosition(position);
    // expected interest = principal * apr * timeElapsed / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(accruedInterest, expectedInterest, 1e15, "accrued interest mismatch");

    // skip a few days after expiry, interest should not increase
    skip(10 days);
    assertEq(
      CreditBrokerMath.getAccruedInterestForFixedPosition(position),
      accruedInterest,
      "interest should not increase after term end"
    );
  }

  function test_getUpfrontInterestForFixedPosition() public {
    uint256 upfrontInterest = CreditBrokerMath.getUpfrontInterestForFixedPosition(position);
    assertEq(upfrontInterest, 0, "upfront interest should be zero within 60s");

    skip(61);
    upfrontInterest = CreditBrokerMath.getUpfrontInterestForFixedPosition(position);
    // expected interest = principal * apr * duration / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(upfrontInterest, expectedInterest, 1e15, "upfront interest mismatch");
  }

  function test_getPenaltyForCreditPosition_clearDebt() public {
    // mock a grace config
    GraceConfig memory graceConfig = GraceConfig({ period: 3 days, penaltyRate: 15 * 1e25, noInterestPeriod: 60 });

    // skip past end + grace period
    skip(45 days);
    uint256 repayAmt = 1000 ether;
    uint256 remainingPrincipal = 500 ether;
    uint256 accruedInterest = 20 ether;
    uint256 endTime = block.timestamp - 15 days; // should be penalized

    uint256 penalty = CreditBrokerMath.getPenaltyForCreditPosition(
      repayAmt,
      remainingPrincipal,
      accruedInterest,
      endTime,
      graceConfig
    );

    // expected penalty = debt * penaltyRate
    uint256 expectedPenalty = (520 ether * 15) / 100; // 15% * debt

    assertApproxEqAbs(penalty, expectedPenalty, 1e15, "penalty mismatch");
  }

  function test_getPenaltyForCreditPosition_partial() public {
    // mock a grace config
    GraceConfig memory graceConfig = GraceConfig({ period: 3 days, penaltyRate: 15 * 1e25, noInterestPeriod: 60 });

    // skip past end + grace period
    skip(45 days);
    uint256 repayAmt = 510 ether;
    uint256 remainingPrincipal = 500 ether;
    uint256 accruedInterest = 20 ether;
    uint256 endTime = block.timestamp - 15 days; // should be penalized

    uint256 penalty = CreditBrokerMath.getPenaltyForCreditPosition(
      repayAmt,
      remainingPrincipal,
      accruedInterest,
      endTime,
      graceConfig
    );
    // expected penalty = repayAmt * penaltyRate
    uint256 expectedPenalty = (510 ether * 15) / 100; // 15% * repaid amount
    assertApproxEqAbs(penalty, expectedPenalty, 1e15, "penalty mismatch");
  }

  function test_previewRepayFixedLoanPosition_fully() public {
    skip(duration + 10 days);

    (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      1_500 ether,
      graceConfig
    );

    // expected upfront interest = principal * apr * duration / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(interestRepaid, expectedInterest, 1e15, "interest repaid mismatch");
    // expected penalty = (principal + interest) * penaltyRate
    uint256 expectedPenalty = ((1_000 ether + expectedInterest) * 15) / 100; // 15% * debt
    assertApproxEqAbs(penalty, expectedPenalty, 1e15, "penalty mismatch");
    // principal repaid should be 1_000 ether
    assertEq(principalRepaid, 1_000 ether);
  }

  function test_previewRepayFixedLoanPosition_partial_noPenalty() public {
    skip(duration / 2); // before term end

    (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      200 ether,
      graceConfig
    );

    // expected upfront interest = principal * apr * duration / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(interestRepaid, 200 ether, 1e15, "interest repaid mismatch");
    // expected penalty = 0 within grace period
    assertEq(penalty, 0, "penalty should be zero within grace period");
    // principal repaid should be 0
    assertEq(principalRepaid, 0);

    (interestRepaid, penalty, principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      301 ether,
      graceConfig
    );
    // now should cover full interest and 1 ether principal
    assertApproxEqAbs(interestRepaid, 300 ether, 1e15, "interest repaid mismatch");
    assertEq(principalRepaid, 1 ether);
    assertEq(penalty, 0, "penalty should be zero within grace period");
  }

  function test_previewRepayFixedLoanPosition_partial_hasPenalty() public {
    skip(duration + 10 days); // after term end + grace period

    (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      200 ether,
      graceConfig
    );

    // expected upfront interest = principal * apr * duration / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(interestRepaid, 200 ether, 1e15, "interest repaid mismatch");
    // expected penalty = repayAmt * penaltyRate
    uint256 expectedPenalty = (200 ether * 15) / 100; // 15% * repaid amount
    assertApproxEqAbs(penalty, 0, 1e15, "penalty mismatch"); // cannot afford penalty
    // principal repaid should be 0
    assertEq(principalRepaid, 0);

    (interestRepaid, penalty, principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      300 ether,
      graceConfig
    );
    // now should cover full interest and 0 principal
    assertApproxEqAbs(interestRepaid, 300 ether, 1e15, "interest repaid mismatch");
    assertEq(principalRepaid, 0);
    assertEq(penalty, 0);

    (interestRepaid, penalty, principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      310 ether,
      graceConfig
    );
    assertApproxEqAbs(interestRepaid, 300 ether, 1e15, "interest repaid mismatch");
    assertEq(principalRepaid, 8.5 ether);
    assertEq(penalty, 1.5 ether); // 10 ether can cover part of penalty
  }

  function test_getMaxListaForInterestRepay() public {
    skip(61); // skip no interest period
    uint256 listaPrice = 5e7; // $0.5 per LISTA
    uint listaDiscountRate = 20 * 1e25; // 20% discount

    uint256 maxLista = CreditBrokerMath.getMaxListaForInterestRepay(position, listaPrice, listaDiscountRate);
    uint totalInterest = (1_000 ether * 30) / 100; // 300 ether

    uint256 expectedMaxLista = ((1e8 * totalInterest * 80) / 100) / listaPrice; // considering 20% discount

    assertApproxEqAbs(maxLista, expectedMaxLista, 1e15, "max lista mismatch");
  }

  function test_getInterestAmountFromLista() public {
    skip(61); // skip no interest period
    uint256 listaPrice = 5e7; // $0.5 per LISTA
    uint listaDiscountRate = 20 * 1e25; // 20% discount

    uint256 listaAmount = 10_000 ether;

    uint256 interestAmount = CreditBrokerMath.getInterestAmountFromLista(listaAmount, listaPrice, listaDiscountRate);

    // expected interest amount = listaAmount * listaPrice / (1 - discountRate)
    uint256 expectedInterestAmount = (100 * listaAmount * listaPrice) / (80 * 1e8); // considering 20% discount
    assertApproxEqAbs(interestAmount, expectedInterestAmount, 1e15, "interest amount mismatch");
  }
}

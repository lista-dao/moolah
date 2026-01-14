pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { CreditBrokerMath, RATE_SCALE } from "../../src/broker/libraries/CreditBrokerMath.sol";
import { ICreditBroker, FixedLoanPosition, FixedTermAndRate, GraceConfig, FixedTermType } from "../../src/broker/interfaces/ICreditBroker.sol";

contract CreditBrokerMathTest is Test {
  function setUp() public {}

  function test_getAccruedInterestForFixedPosition() public {
    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 365 days;
    uint256 apr = 13e26; // 30%

    // mock a fixed position
    FixedLoanPosition memory position = FixedLoanPosition({
      termType: FixedTermType.ACCRUE_INTEREST,
      posId: 1,
      principal: 1_000 ether,
      apr: apr,
      start: block.timestamp,
      end: block.timestamp + duration,
      lastRepaidTime: block.timestamp,
      interestRepaid: 0,
      principalRepaid: 0,
      noInterestUntil: 0
    });

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
    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 365 days;
    uint256 apr = 13e26; // 30%

    // mock a fixed position
    FixedLoanPosition memory position = FixedLoanPosition({
      termType: FixedTermType.UPFRONT_INTEREST,
      posId: 1,
      principal: 1_000 ether,
      apr: apr,
      start: block.timestamp,
      end: block.timestamp + duration,
      lastRepaidTime: block.timestamp,
      interestRepaid: 0,
      principalRepaid: 0,
      noInterestUntil: block.timestamp + 60
    });
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
}

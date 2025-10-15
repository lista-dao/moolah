// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FixedLoanPosition, DynamicLoanPosition } from "../interfaces/IBroker.sol";

uint256 constant RATE_SCALE = 10 ** 27;

library BrokerMath {
  // =========================== //
  //           Helpers           //
  // =========================== //
  function getTotalDebt(
    FixedLoanPosition[] memory fixedPositions,
    DynamicLoanPosition memory dynamicPosition,
    uint256 currentRate
  ) public view returns (uint256 totalDebt) {
    // [1] total debt from fixed position
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      // add principal
      totalDebt += _fixedPos.principal - _fixedPos.principalRepaid;
      // add interest
      totalDebt += getAccruedInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }
    // [2] total debt from dynamic position
    totalDebt += denormalizeBorrowAmount(dynamicPosition.normalizedDebt, currentRate);
  }

  function mulDivCeiling(uint256 a, uint256 b, uint256 c) public pure returns (uint256) {
    return Math.mulDiv(a, b, c, Math.Rounding.Ceil);
  }

  function mulDivFlooring(uint256 a, uint256 b, uint256 c) public pure returns (uint256) {
    return Math.mulDiv(a, b, c, Math.Rounding.Floor);
  }

  // =========================== //
  //          Fixed Loan         //
  // =========================== //

  /**
   * @dev Get the accrued interest for a fixed loan position
   * @param position The fixed loan position to get the interest for
   */
  function getAccruedInterestForFixedPosition(FixedLoanPosition memory position) public view returns (uint256) {
    uint256 cap = block.timestamp > position.end ? position.end : block.timestamp;
    uint256 start = position.lastRepaidTime > position.end ? position.end : position.lastRepaidTime;
    // time elapsed since last repayment
    uint256 timeElapsed = cap - start;
    if (position.principal == 0 || timeElapsed == 0) return 0;
    // accrued interest = principal * APR(per second) * timeElapsed
    return
      Math.mulDiv(
        position.principal - position.principalRepaid,
        _aprPerSecond(position.apr) * timeElapsed,
        RATE_SCALE,
        Math.Rounding.Ceil
      );
  }

  /**
   * @dev Get the penalty for a fixed loan position
   * @param position The fixed loan position to get the penalty for
   * @param repayAmt The actual repay amount (repay amount excluded accrued interest)
   */
  function getPenaltyForFixedPosition(
    FixedLoanPosition memory position,
    uint256 repayAmt
  ) public view returns (uint256 penalty) {
    // only early repayment will incur penalty
    if (block.timestamp > position.end) return 0;
    // time left before expiration
    uint256 timeLeft = position.end - block.timestamp;
    // penalty = (repayAmt * APR) * timeleft/term * 1/2
    penalty = Math.mulDiv(
      Math.mulDiv(repayAmt, _aprPerSecond(position.apr), RATE_SCALE, Math.Rounding.Ceil), // repayAmt * APR(per second)
      timeLeft,
      2,
      Math.Rounding.Ceil
    );
  }

  /**
   * @dev Convert annual percentage rate (APR) to a per-second rate
   * @param apr The annual percentage rate (APR) scaled by RATE_SCALE
   * @return The per-second rate scaled by RATE_SCALE
   */
  function _aprPerSecond(uint256 apr) internal pure returns (uint256) {
    if (apr <= RATE_SCALE) return 0;
    return Math.mulDiv(apr - RATE_SCALE, 1, 365 days, Math.Rounding.Floor);
  }

  /**
   * @dev Preview the repayment of a fixed loan position
   * @param position The fixed loan position to preview the repayment for
   * @param amount The amount to repay
   * @return interestRepaid The amount of interest that will be repaid
   * @return penalty The amount of penalty that will be incurred
   * @return principalRepaid The amount of principal that will be repaid
   */
  function previewRepayFixedLoanPosition(
    FixedLoanPosition memory position,
    uint256 amount
  ) public view returns (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) {
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    // get outstanding accrued interest
    uint256 accruedInterest = getAccruedInterestForFixedPosition(position) - position.interestRepaid;

    // initialize repay amounts
    interestRepaid = amount < accruedInterest ? amount : accruedInterest;
    uint256 repayPrincipalAmt = amount - interestRepaid;

    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // ----- penalty
      penalty = getPenaltyForFixedPosition(
        position,
        repayPrincipalAmt > remainingPrincipal ? remainingPrincipal : repayPrincipalAmt
      );
      repayPrincipalAmt -= penalty;

      // ----- principal
      if (repayPrincipalAmt > 0) {
        // even if user transferred more than needed, we only repay what is needed
        // this allows user to fully repay, tokens unused will be returned to user
        principalRepaid = repayPrincipalAmt > remainingPrincipal ? remainingPrincipal : repayPrincipalAmt;
      }
    }
  }

  // =========================== //
  //         Dynamic Loan        //
  // =========================== //

  /**
   * @dev Normalize the borrow amount based on the current interest rate
   * @param borrowAmount The original borrow amount
   * @param rate The current interest rate
   * @return The normalized borrow amount
   */
  function normalizeBorrowAmount(uint256 borrowAmount, uint256 rate) public pure returns (uint256) {
    return Math.mulDiv(borrowAmount, RATE_SCALE, rate, Math.Rounding.Ceil);
  }

  /**
   * @dev Denormalize the borrow amount based on the current interest rate
   * @param normalizedDebt The normalized borrow amount
   * @param rate The current interest rate
   * @return the actual borrow amount
   */
  function denormalizeBorrowAmount(uint256 normalizedDebt, uint256 rate) public pure returns (uint256) {
    return Math.mulDiv(normalizedDebt, rate, RATE_SCALE, Math.Rounding.Ceil);
  }

  /**
   * @dev Calculates x ** n with base b
   * @param x The base (scaled APR factor for the time period, e.g., for 1 year)
   * @param n The exponent (the time elapsed in seconds)
   * @param b The scaling factor
   */
  function _rpow(uint x, uint n, uint b) public pure returns (uint z) {
    /// @solidity memory-safe-assembly
    assembly {
      switch x
      case 0 {
        switch n
        case 0 {
          z := b
        }
        default {
          z := 0
        }
      }
      default {
        switch mod(n, 2)
        case 0 {
          z := b
        }
        default {
          z := x
        }
        let half := div(b, 2) // for rounding.
        for {
          n := div(n, 2)
        } n {
          n := div(n, 2)
        } {
          let xx := mul(x, x)
          if iszero(eq(div(xx, x), x)) {
            revert(0, 0)
          }
          let xxRound := add(xx, half)
          if lt(xxRound, xx) {
            revert(0, 0)
          }
          x := div(xxRound, b)
          if mod(n, 2) {
            let zx := mul(z, x)
            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
              revert(0, 0)
            }
            let zxRound := add(zx, half)
            if lt(zxRound, zx) {
              revert(0, 0)
            }
            z := div(zxRound, b)
          }
        }
      }
    }
  }

  function _rmul(uint x, uint y) public pure returns (uint z) {
    unchecked {
      z = x * y;
      require(y == 0 || z / y == x);
      z = z / RATE_SCALE;
    }
  }
}

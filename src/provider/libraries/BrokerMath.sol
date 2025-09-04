// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {
  IBroker,
  FixedLoanPosition,
  DynamicLoanPosition,
  FixedTermAndRate
} from "../interfaces/IBroker.sol";


library BrokerMath {

  uint256 constant public DENOMINATOR = 10 ** 27;

  // =========================== //
  //          Fixed Loan         //
  // =========================== //

  /**
  * @dev Get the interest for a fixed loan position
  * @param position The fixed loan position to get the interest for
  */
  function getAccruedInterestForFixedPosition(FixedLoanPosition memory position) public view returns (uint256) {
    // term
    uint256 term = position.end - position.start;
    // accrued interest = principal * APR * (block.timestamp - lastRepaidTime) / term
    return Math.mulDiv(
      Math.mulDiv(position.principal, position.apr, DENOMINATOR, Math.Rounding.Ceil), // principal * APR
      block.timestamp - position.lastRepaidTime,
      term,
      Math.Rounding.Ceil
    );
  }

  /**
  * @dev Get the penalty for a fixed loan position
  * @param position The fixed loan position to get the penalty for
  * @param repayAmt The actual repay amount (repay amount excluded accrued interest)
  */
  function getPenaltyForFixedPosition(FixedLoanPosition memory position, uint256 repayAmt) public view returns (uint256 penalty) {
    // only early repayment will incur penalty
    if (block.timestamp > position.end) return 0;
    // time left before expiration
    uint256 timeLeft = position.end - block.timestamp;
    // duration of the loan
    uint256 term = position.end - position.start;
    // penalty = (repayAmt * APR) * timeleft/term * 1/2
    penalty = Math.mulDiv(
      Math.mulDiv(repayAmt, position.apr, DENOMINATOR, Math.Rounding.Ceil), // repayAmt * APR
      timeLeft,
      term * 2,
      Math.Rounding.Ceil
    );
  }


  // =========================== //
  //         Dynamic Loan        //
  // =========================== //


  function calculateNewRate(uint base, uint rate, uint elapsed) public pure returns (uint newRate) {
    newRate = _rmul(
      _rpow(_add(base, rate), elapsed, DENOMINATOR),
      rate
    );
  }

  function _rpow(uint x, uint n, uint b) internal pure returns (uint z) {
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

  function _rmul(uint x, uint y) internal pure returns (uint z) {
    unchecked {
      z = x * y;
      require(y == 0 || z / y == x);
      z = z / BrokerMath.DENOMINATOR;
    }
  }

  function _add(uint x, uint y) internal pure returns (uint z) {
    unchecked {
      z = x + y;
      require(z >= x);
    }
  }

  function _diff(uint x, uint y) internal pure returns (int z) {
    unchecked {
      z = int(x) - int(y);
      require(int(x) >= 0 && int(y) >= 0);
    }
  }
  
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UtilsLib } from "../../moolah/libraries/UtilsLib.sol";
import { MathLib, WAD } from "../../moolah/libraries/MathLib.sol";
import { SharesMathLib } from "../../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../../moolah/interfaces/IMoolah.sol";
import { ICreditBroker, FixedLoanPosition } from "../interfaces/ICreditBroker.sol";
import { IOracle } from "../../moolah/interfaces/IOracle.sol";
import { PriceLib } from "../../moolah/libraries/PriceLib.sol";

uint256 constant RATE_SCALE = 10 ** 27;
uint256 constant ONE_USD = 1e8; // 8 decimal places
uint256 constant CREDIT_TOKEN_PRICE = 1e8;

library CreditBrokerMath {
  using MathLib for uint128;
  using MathLib for uint256;
  using SharesMathLib for uint256;

  // =========================== //
  //           Helpers           //
  // =========================== //
  function peek(address token, address user, address moolah, address oracle) public view returns (uint256 price) {
    ICreditBroker broker = ICreditBroker(address(this));
    address loanToken = broker.LOAN_TOKEN();
    address collateralToken = broker.COLLATERAL_TOKEN();
    IMoolah moolah = IMoolah(moolah);
    Id marketId = broker.MARKET_ID();
    // loan token's price never changes
    if (token == loanToken) {
      return ONE_USD; // lisUSD or USDT or U price
    } else if (token == collateralToken) {
      /*
        Broker accrues interest, so collateral price is adjusted downward,
        this lets Moolah detect risk as interest grows, despite its 0% rate.
        [A] Collateral Market Price
        [B] Broker Total Debt (included interest)
        [C] Moolah Debt (0% rate)
        [D] Collateral Amount
        new collateral price  = A - (B-C)/D
      */
      // the total debt of the user (principal + interest)
      uint256 debtAtBroker = getTotalDebt(broker.userFixedPositions(user));
      // fetch collateral price from oracle
      uint256 collateralPrice = CREDIT_TOKEN_PRICE;
      // get user's position info
      Position memory _position = moolah.position(marketId, user);
      // in case there is no collaterals
      if (_position.collateral == 0) {
        return collateralPrice;
      }
      // get market info
      Market memory _market = moolah.market(marketId);
      // convert shares to borrowed amount (Moolah's debt)
      uint256 debtAtMoolah = uint256(_position.borrowShares).toAssetsUp(
        _market.totalBorrowAssets,
        _market.totalBorrowShares
      );
      // get decimal places
      uint8 collateralDecimals = IERC20Metadata(collateralToken).decimals();
      uint8 loanDecimals = IERC20Metadata(loanToken).decimals();
      // calculate manipulated price
      uint256 deltaDebt = UtilsLib.zeroFloorSub(debtAtBroker, debtAtMoolah);
      // Convert (brokerDebt − moolahDebt) per unit collateral into an 8‑decimal price.
      // deltaDebt is in loan token units (10^loanDecimals); collateral is in 10^collateralDecimals.
      // Scale: ceil(deltaDebt * 10^(8 + collateralDecimals) / (collateral * 10^loanDecimals)).
      // 10^(collateralDecimals) cancels collateral units; 10^8 sets price precision.
      // Ceiling rounding avoids under‑deduction (more conservative).
      uint256 deduction = mulDivCeiling(
        deltaDebt,
        10 ** (8 + uint256(collateralDecimals)),
        _position.collateral * (10 ** uint256(loanDecimals))
      );
      price = deduction >= collateralPrice ? 0 : (collateralPrice - deduction);
      return price;
    }
  }

  /**
   * @dev Ensure every position's principal either cleared or larger than Moolah.minLoan
   * @param user The address of the user
   * @param moolah The address of the Moolah contract
   */
  function checkPositionsMeetsMinLoan(address user, address moolah) public view returns (bool isValid) {
    // get positions
    ICreditBroker broker = ICreditBroker(address(this));
    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(user);
    // assume valid first
    isValid = true;
    IMoolah _moolah = IMoolah(moolah);
    uint256 minLoan = _moolah.minLoan(_moolah.idToMarketParams(ICreditBroker(address(this)).MARKET_ID()));
    // ensure each position either zero or larger than minLoan
    // check fixed positions
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      uint256 fixedPosDebt = _fixedPos.principal - _fixedPos.principalRepaid;
      if (fixedPosDebt > 0 && fixedPosDebt < minLoan) {
        isValid = false;
      }
    }
  }

  /**
   * @dev Get the total debt for a user
   * @param fixedPositions The fixed loan positions of the user
   * @return totalDebt The total debt of the user
   */
  function getTotalDebt(FixedLoanPosition[] memory fixedPositions) public view returns (uint256 totalDebt) {
    // [1] total debt from fixed position
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      // add principal
      totalDebt += _fixedPos.principal - _fixedPos.principalRepaid;
      // add interest
      totalDebt += getAccruedInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }
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
    return Math.mulDiv(apr - RATE_SCALE, 1, 365 days, Math.Rounding.Ceil);
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

  /**
   * @dev Revert if duplicate position IDs are found
   * @param posIds The position IDs to check for duplicates
   */
  function _revertIfDuplicatePosIds(uint256[] calldata posIds) internal pure {
    for (uint256 i = 0; i < posIds.length; i++) {
      uint256 posId = posIds[i];
      for (uint256 j = i + 1; j < posIds.length; j++) {
        require(posIds[j] != posId, "Broker/duplicate-pos-id");
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
   * @param roundUp Whether to round up or down
   * @return The normalized borrow amount
   */
  function normalizeBorrowAmount(uint256 borrowAmount, uint256 rate, bool roundUp) public pure returns (uint256) {
    return Math.mulDiv(borrowAmount, RATE_SCALE, rate, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
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

  // =========================== //
  //      Liquidation Helper     //
  // =========================== //

  /**
   * @dev Get the debt at Moolah for a user
   * @param user The address of the user
   */
  function getDebtAtMoolah(address user) public view returns (uint256) {
    ICreditBroker broker = ICreditBroker(address(this));
    IMoolah moolah = broker.MOOLAH();
    Id marketId = broker.MARKET_ID();
    Position memory position = moolah.position(marketId, user);
    Market memory market = moolah.market(marketId);
    return uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
  }

  /**
   * @dev Deduct the debt from a fixed loan position
   * @param interestToDeduct The amount of interest to deduct
   * @param principalToDeduct The amount of principal to deduct
   * @param p The fixed loan position to deduct from
   * @return interestToDeduct The remaining amount of interest to deduct
   * @return principalToDeduct The remaining amount of principal to deduct
   * @return p The updated fixed loan position
   */
  function deductFixedPositionDebt(
    uint256 interestToDeduct,
    uint256 principalToDeduct,
    FixedLoanPosition memory p
  ) public view returns (uint256, uint256, FixedLoanPosition memory) {
    // remaining principal before repayment
    uint256 remainingPrincipal = p.principal - p.principalRepaid;
    // get accrued interest from LAST REPAID TIME to NOW
    uint256 accruedInterest = getAccruedInterestForFixedPosition(p) - p.interestRepaid;

    // initialize repay amounts
    uint256 repayInterestAmt = UtilsLib.min(interestToDeduct, accruedInterest);
    uint256 repayPrincipalAmt = UtilsLib.min(principalToDeduct, remainingPrincipal);

    // repay interest first, it might be zero if user just repaid before
    if (repayInterestAmt > 0) {
      // update repaid interest amount
      p.interestRepaid += repayInterestAmt;
      // supply interest into vault as revenue
      interestToDeduct -= repayInterestAmt;
    }
    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // update repaid principal amount
      principalToDeduct -= repayPrincipalAmt;
      p.principalRepaid += repayPrincipalAmt;
      // reset repaid interest to zero (all accrued interest has been cleared)
      p.interestRepaid = 0;
      // reset repaid time to now
      p.lastRepaidTime = block.timestamp;
    }

    return (interestToDeduct, principalToDeduct, p);
  }

  /**
   * @dev sorting by end time ascending and filter out fully repaid positions
   *      - this is a simple insertion sort, gas cost is O(n^2) in worst case,
   *      - works well for small arrays as user's number of fixed positions is limited
   * @param positions The fixed loan positions to sort
   */
  function sortAndFilterFixedPositions(
    FixedLoanPosition[] memory positions
  ) public pure returns (FixedLoanPosition[] memory) {
    uint256 len = positions.length;
    FixedLoanPosition[] memory filtered = new FixedLoanPosition[](len);
    uint256 count;
    for (uint256 i = 0; i < len; i++) {
      FixedLoanPosition memory p = positions[i];
      if (p.principal > p.principalRepaid) {
        uint256 j = count;
        while (j > 0) {
          FixedLoanPosition memory prev = filtered[j - 1];
          if (prev.end <= p.end) {
            break;
          }
          filtered[j] = prev;
          j--;
        }
        filtered[j] = p;
        count++;
      }
    }
    // trim `filtered` to length `count`
    assembly {
      mstore(filtered, count)
    }
    return filtered;
  }
}

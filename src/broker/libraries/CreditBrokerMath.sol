// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UtilsLib } from "../../moolah/libraries/UtilsLib.sol";
import { MathLib, WAD } from "../../moolah/libraries/MathLib.sol";
import { SharesMathLib } from "../../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../../moolah/interfaces/IMoolah.sol";
import { ICreditBroker, FixedLoanPosition, GraceConfig, FixedTermType } from "../interfaces/ICreditBroker.sol";
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
      return ONE_USD; // U price
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
        break;
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
      totalDebt += getInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }
  }

  /**
   * @dev Get the remaining debt for a fixed loan position
   * @param fixedPosition The fixed loan position
   */
  function getPositionDebt(
    FixedLoanPosition memory fixedPosition
  ) external view returns (uint256 remainingPrincipal, uint256 remainingInterest) {
    // remaining principal before repayment
    remainingPrincipal = fixedPosition.principal - fixedPosition.principalRepaid;
    // get outstanding accrued interest
    remainingInterest = getInterestForFixedPosition(fixedPosition) - fixedPosition.interestRepaid;
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
    require(position.termType == FixedTermType.ACCRUE_INTEREST, "broker/not-accrue-interest");

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
   * @dev Get the total interest for a fixed loan position, for upfront interest repayment
   * @param position The fixed loan position to get the total interest for
   */
  function getUpfrontInterestForFixedPosition(FixedLoanPosition memory position) public view returns (uint256) {
    require(position.termType == FixedTermType.UPFRONT_INTEREST, "broker/not-upfront-interest");

    // return zero if within no interest period
    if (block.timestamp <= position.noInterestUntil) {
      return 0;
    }

    // total interest = principal * (APR - 1) * term / 365 days
    uint256 term = position.end - position.start;
    uint256 totalInterest = Math.mulDiv(
      position.principal,
      Math.mulDiv(position.apr - RATE_SCALE, term, 365 days, Math.Rounding.Ceil),
      RATE_SCALE,
      Math.Rounding.Ceil
    );
    return totalInterest;
  }

  /**
   * @dev Get the interest for a fixed loan position; interest can be accrued or upfront, according to term type
   * @param position The fixed loan position to get the interest for
   */
  function getInterestForFixedPosition(FixedLoanPosition memory position) public view returns (uint256) {
    FixedTermType termType = position.termType;

    // if accrued interest, return accrued interest
    if (termType == FixedTermType.ACCRUE_INTEREST) {
      return getAccruedInterestForFixedPosition(position);
    } else if (termType == FixedTermType.UPFRONT_INTEREST) {
      return getUpfrontInterestForFixedPosition(position);
    } else {
      revert("broker/invalid-fixed-term-type");
    }
  }

  /**
   * @dev Get the penalty for a credit position if repaid after grace period
   *
   * | ---- Fixed term --- | ---- Grace period ---- | After due time
   * | --------------- no   penalty --------------- | penalty applies
   * start                 end                    dueTime
   *
   * @param remainingPrincipal The remaining principal amount
   * @param accruedInterest The accrued interest amount
   * @param endTime The end time of the fixed loan position
   * @param graceConfig The grace period configuration
   */
  function getPenaltyForCreditPosition(
    uint256 remainingPrincipal,
    uint256 accruedInterest, // FE method, know penalty on a position before repay
    uint256 endTime,
    GraceConfig memory graceConfig
  ) public view returns (uint256) {
    uint256 dueTime = endTime + graceConfig.period;
    // if within grace period, no penalty
    if (block.timestamp <= dueTime) return 0;

    // maximum repayable amount = remaining principal + penalty on the debt
    uint256 debt = remainingPrincipal + accruedInterest;
    uint256 penalty = Math.mulDiv(debt, graceConfig.penaltyRate, RATE_SCALE, Math.Rounding.Ceil);
    return penalty;
  }

  /**
   * @dev Calculate the max LISTA amount accpetable for repaying interest
   * @param position The fixed loan position
   * @param listaPrice The current LISTA price in loan token (8 decimal places)
   * @param discountRate The discount rate for LISTA repayment (scaled by RATE_SCALE)
   */
  function getMaxListaForInterestRepay(
    FixedLoanPosition memory position,
    uint256 listaPrice,
    uint256 discountRate
  ) external view returns (uint256) {
    // get outstanding accrued interest
    uint256 accruedInterest = getInterestForFixedPosition(position) - position.interestRepaid;

    uint256 interestAfterDiscount = Math.mulDiv(
      accruedInterest,
      RATE_SCALE - discountRate,
      RATE_SCALE,
      Math.Rounding.Ceil
    );

    // convert interest amount to LISTA amount
    return Math.mulDiv(interestAfterDiscount, 1e8, listaPrice, Math.Rounding.Ceil);
  }

  /**
   * @dev Calculate loan token amount equivalent to given LISTA amount
   * @param listaAmount The LISTA amount
   * @param listaPrice The current LISTA price in loan token (8 decimal places)
   * @param discountRate The discount rate for LISTA repayment (scaled by RATE_SCALE)
   */
  function getInterestAmountFromLista(
    uint256 listaAmount,
    uint256 listaPrice,
    uint256 discountRate
  ) public view returns (uint256) {
    // convert LISTA amount to loan token amount with discount
    uint256 loanTokenAmount = Math.mulDiv(listaAmount, listaPrice, 1e8, Math.Rounding.Floor);
    return Math.mulDiv(loanTokenAmount, RATE_SCALE, RATE_SCALE - discountRate, Math.Rounding.Floor);
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
   * @param graceConfig The grace period configuration
   * @return interestRepaid The amount of interest that will be repaid
   * @return penalty The amount of penalty that will be incurred due to grace period end
   * @return principalRepaid The amount of principal that will be repaid
   */
  function previewRepayFixedLoanPosition(
    FixedLoanPosition memory position,
    uint256 amount,
    GraceConfig memory graceConfig
  ) external view returns (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) {
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    // get outstanding accrued interest
    uint256 remainingInterest = getInterestForFixedPosition(position) - position.interestRepaid;

    // initialize repay amounts
    interestRepaid = amount < remainingInterest ? amount : remainingInterest;
    uint256 repayPrincipalAmt = amount - interestRepaid;

    // if this is penalized position, ensure full repayment
    penalty = getPenaltyForCreditPosition(remainingPrincipal, remainingInterest, position.end, graceConfig);
    if (penalty > 0) {
      uint256 totalRepayNeeded = remainingInterest + remainingPrincipal + penalty;
      if (amount < totalRepayNeeded) return (0, 0, 0);
    }

    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
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
   * @dev Get the total repayable amount needed for a fixed loan position
   * @param position The fixed loan position to get the total repayable amount for
   * @param graceConfig The grace period configuration
   */
  function getTotalRepayNeeded(
    FixedLoanPosition memory position,
    GraceConfig memory graceConfig
  ) external view returns (uint256 totalRepayNeeded) {
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    // get outstanding accrued interest
    uint256 remainingInterest = getInterestForFixedPosition(position) - position.interestRepaid;

    // calculate penalty if any
    uint256 penalty = getPenaltyForCreditPosition(remainingPrincipal, remainingInterest, position.end, graceConfig);

    totalRepayNeeded = remainingPrincipal + remainingInterest + penalty;
  }
}

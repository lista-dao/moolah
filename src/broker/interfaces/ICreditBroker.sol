// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id, MarketParams, IMoolah } from "moolah/interfaces/IMoolah.sol";

enum FixedTermType {
  ACCRUE_INTEREST, // 0: interest is accrued over time, user pays interest based on time elapsed
  UPFRONT_INTEREST // 1: interest is paid upfront, user pays full interest at the beginning
}

struct FixedTermAndRate {
  uint256 termId;
  uint256 duration;
  uint256 apr;
  FixedTermType termType;
}

struct FixedLoanPosition {
  FixedTermType termType;
  uint256 posId;
  uint256 principal;
  uint256 apr;
  uint256 start;
  uint256 end;
  uint256 lastRepaidTime; // the last time interest was repaid, initialized to `start`, set to now when partial of principal is repaid
  uint256 interestRepaid; // the interest repaid since `lastRepaidTime`, reset to zero when partial of principal is repaid
  uint256 principalRepaid; // the principal repaid
  uint256 noInterestUntil; // only for upfront interest term type, the time until which no interest is charged
}

struct GraceConfig {
  /// @dev grace period in seconds; if users repay within the grace period after term end, no penalty will be charged
  /// @dev e.g., 3 days = 3 * 24 * 3600
  uint256 period;
  /// @dev penalty rate for delayed repayment after grace period; e.g., 15% = 0.15 * RATE_SCALE
  /// @dev e.g., if penaltyRate is 15%, user should pay additional 15% * userDebt as penalty after grace period
  uint256 penaltyRate;
  /// @dev no interest period in seconds, small value; 1 minute by default
  /// @dev if users repay within this period after borrowing, no interest will be charged
  /// @dev used for upfront interest term type only
  uint256 noInterestPeriod;
}

/// @dev Credit Broker Base interface
/// maintain lightweight for Moolah
interface ICreditBrokerBase {
  /// @dev user will borrow this token against their collateral
  function LOAN_TOKEN() external view returns (address);
  /// @dev user will deposit this token as collateral
  function COLLATERAL_TOKEN() external view returns (address);
  /// @dev the market id of the broker
  function MARKET_ID() external view returns (Id);
  /// @dev the Moolah contract
  function MOOLAH() external view returns (IMoolah);

  /// @dev peek the price of the token per user
  ///      decreasing according to the accruing interest for collateral token
  /// @param token The address of the token to peek
  /// @param user The address of the user to peek
  function peek(address token, address user) external view returns (uint256 price);
}

/// @dev Broker interface
interface ICreditBroker is ICreditBrokerBase {
  /// ------------------------------
  ///            Events
  /// ------------------------------
  event FixedLoanPositionCreated(
    address indexed user,
    uint256 posId,
    uint256 principal,
    uint256 start,
    uint256 end,
    uint256 apr,
    uint256 termId
  );
  event RepaidFixedLoanPosition(
    address indexed user,
    uint256 posId,
    uint256 principal,
    uint256 start,
    uint256 end,
    uint256 apr,
    uint256 principalRepaid,
    bool fullyRepaid
  );
  event FixedLoanPositionRemoved(address indexed user, uint256 posId);
  event MaxFixedLoanPositionsUpdated(uint256 oldMax, uint256 newMax);
  event FixedTermAndRateUpdated(uint256 termId, uint256 duration, uint256 apr);
  event MarketIdSet(Id marketId);
  event BorrowPaused(bool paused);
  event AddedLiquidationWhitelist(address indexed account);
  event GraceConfigUpdated(uint256 newPeriod, uint256 newPenaltyRate, uint256 newNoInterestPeriod);
  event PaidOffPenalizedPosition(address indexed user, uint256 posId, uint256 paidOffTime);
  event RepayInterestWithLista(
    address indexed user,
    uint256 posId,
    uint256 interestAmount,
    uint256 listaAmount,
    uint256 listaPrice
  );

  /// ------------------------------
  ///        View functions
  /// ------------------------------
  /// @dev get the fixed terms available for borrowing
  function getFixedTerms() external view returns (FixedTermAndRate[] memory);

  /// @dev get user's fixed loan positions
  /// @param user The address of the user
  function userFixedPositions(address user) external view returns (FixedLoanPosition[] memory);

  /// @dev get the total debt of a user including principal and interest
  /// @param user The address of the user
  function getUserTotalDebt(address user) external view returns (uint256 totalDebt);

  /// ------------------------------
  ///      External functions
  /// ------------------------------

  /// @dev supply collateral(credit token) to the broker
  /// @param marketParams The market parameters
  /// @param amount The amount of collateral to supply
  /// @param score The credit score of the user
  /// @param proof The merkle proof of the credit score
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) external;

  /// @dev supply collateral and borrow with a fixed rate and term in a single transaction
  /// @param marketParams The market parameters
  /// @param collateralAmount The amount of collateral to supply
  /// @param borrowAmount The amount to borrow
  /// @param termId The ID of the fixed term to use
  /// @param score The credit score of the user
  /// @param proof The merkle proof of the credit score
  function supplyAndBorrow(
    MarketParams memory marketParams,
    uint256 collateralAmount,
    uint256 borrowAmount,
    uint256 termId,
    uint256 score,
    bytes32[] calldata proof
  ) external;

  /// @dev borrow with a fixed rate and term
  /// @param amount The amount to borrow
  /// @param termId The ID of the fixed term to use
  /// @param score The credit score of the user
  /// @param proof The merkle proof of the credit score
  function borrow(uint256 amount, uint256 termId, uint256 score, bytes32[] calldata proof) external;

  /// @dev repay a loan with a fixed rate and term
  /// @param amount The amount to repay
  /// @param posIdx The index of the fixed position to repay
  /// @param onBehalf The address of the user whose position to repay
  function repay(uint256 amount, uint256 posIdx, address onBehalf) external;

  /// @dev withdraw collateral(credit token) from the broker
  /// @param marketParams The market parameters
  /// @param amount The amount of collateral to withdraw
  /// @param score The credit score of the user
  /// @param proof The merkle proof of the credit score
  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) external;

  /// @dev repay loan and withdraw collateral in a single transaction
  /// @param marketParams The market parameters
  /// @param collateralAmount The amount of collateral to withdraw
  /// @param repayAmount The amount to repay
  /// @param posId The position ID to repay
  /// @param score The credit score of the user
  /// @param proof The merkle proof of the credit score
  function repayAndWithdraw(
    MarketParams memory marketParams,
    uint256 collateralAmount,
    uint256 repayAmount,
    uint256 posId,
    uint256 score,
    bytes32[] calldata proof
  ) external;

  /// @dev repay interest using LISTA token, the rest of debt will be in loan token
  /// @param loanTokenAmount The amount of loan token to repay
  /// @param listaAmount The amount of LISTA token to use for interest repayment
  /// @param posId The position ID to repay
  /// @param onBehalf The address of the user whose position to repay
  function repayInterestWithLista(
    uint256 loanTokenAmount,
    uint256 listaAmount,
    uint256 posId,
    address onBehalf
  ) external;
}

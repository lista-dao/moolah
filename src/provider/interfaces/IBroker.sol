// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "moolah/interfaces/IMoolah.sol";

struct FixedTermAndRate {
  uint256 termId;
  uint256 duration;
  uint256 apr;
}

struct FixedLoanPosition {
  uint256 principal;
  uint256 apr;
  uint256 start;
  uint256 end;
  uint256 lastRepaidTime;
  uint256 repaidPrincipal;
}

struct DynamicLoanPosition {
  uint256 principal;
  uint256 normalisedDebt;
}

/// @dev Broker Base interface
/// maintain lightweight for Moolah
interface IBrokerBase {
  /// @dev user will borrow this token against their collateral
  function LOAN_TOKEN() external view returns (address);

  /// @dev user will deposit this token as collateral
  function COLLATERAL_TOKEN() external view returns (address);

  /// @dev peek the price of the token per user
  ///      decreasing according to the accruing interest for collateral token
  /// @param token The address of the token to peek
  /// @param user The address of the user to peek
  function peek(address token, address user) external view returns (uint256 price);
}

/// @dev Broker interface
interface IBroker is IBrokerBase {
  
  /// ------------------------------
  ///            Events
  /// ------------------------------
  event DynamicLoanPositionUpdated(address indexed user, uint256 amount);
  event FixedLoanPositionCreated(
    address indexed user,
    uint256 principal,
    uint256 start,
    uint256 end,
    uint256 apr,
    uint256 termId
  );
  event RepaidFixedLoanPosition(
    address indexed user, 
    uint256 principal,
    uint256 start,
    uint256 end,
    uint256 apr,
    uint256 repaidPrincipal,
    bool fullyRepaid
  );
  event MaxFixedLoanPositionsUpdated(uint256 oldMax, uint256 newMax);
  event FixedTermAndRateUpdated(uint256 termId, uint256 duration, uint256 apr);

  /// ------------------------------
  ///        View functions
  /// ------------------------------
  /// @dev get the fixed terms available for borrowing
  function getFixedTerms() external view returns (FixedTermAndRate[] memory);

  /// ------------------------------
  ///      External functions
  /// ------------------------------
  /// @dev borrow with the dynamic rate scheme
  /// @param amount The amount to borrow
  function borrow(uint256 amount) external;

  /// @dev borrow with a fixed rate and term
  /// @param amount The amount to borrow
  /// @param termId The ID of the fixed term to use
  function borrow(uint256 amount, uint256 termId) external;

  /// @dev repay a loan with the dynamic rate scheme
  /// @param amount The amount to repay
  function repay(uint256 amount) external;

  /// @dev repay a loan with a fixed rate and term
  /// @param amount The amount to repay
  /// @param posIdx The index of the fixed position to repay
  function repay(uint256 amount, uint256 posIdx) external;

  /// @dev liquidate a user's position
  /// @param marketId The market id of the broker belongs to
  /// @param user The address of the user position is being liquidated
  function liquidate(Id marketId, address user) external;

  /// @dev refinance expired fixed positions to dynamic
  /// @param user The address of the user to refinance
  /// @param positionIdxs The indices of the fixed positions to refinance
  function refinanceExpiredToDynamic(address user, uint256[] calldata positionIdxs) external;
}

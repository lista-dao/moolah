// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBroker, FixedLoanPosition, DynamicLoanPosition } from "../interfaces/IBroker.sol";
import { IRateCalculator } from "../interfaces/IRateCalculator.sol";
import { IBrokerInterestRelayer } from "../interfaces/IBrokerInterestRelayer.sol";
import { BrokerMath } from "./BrokerMath.sol";

import { Id, IMoolah, MarketParams, Market, Position } from "../../moolah/interfaces/IMoolah.sol";
import { SharesMathLib } from "../../moolah/libraries/SharesMathLib.sol";
import { UtilsLib } from "../../moolah/libraries/UtilsLib.sol";
import { IWBNB } from "../../provider/interfaces/IWBNB.sol";

/// @title LendingBroker operator library
/// @notice Houses the bytecode for `repay`, `repay(fixed)`, and `repayAll` so the broker
///         itself stays under the EIP-170 size limit. Invoked via DELEGATECALL, so all
///         state mutations apply to LendingBroker's storage and events surface from
///         LendingBroker's address.
library LendingBrokerOperatorLib {
  using SafeERC20 for IERC20;
  using SharesMathLib for uint256;
  using UtilsLib for uint256;

  // ------- Errors (must match LendingBroker's set) -------
  error ZeroAmount();
  error ZeroAddress();
  error NothingToRepay();
  error NativeNotSupported();
  error InsufficientAmount();
  error NativeTransferFailed();
  error PositionNotFound();

  // ------- Events (must match IBroker signatures so indexers keep working) -------
  event DynamicLoanPositionRepaid(address indexed user, uint256 repaid, uint256 principalLeft);
  event RepaidFixedLoanPosition(
    address indexed user,
    uint256 posId,
    uint256 principal,
    uint256 start,
    uint256 end,
    uint256 apr,
    uint256 principalRepaid,
    uint256 repayPrincipal,
    uint256 repayInterest,
    uint256 repayPenalty,
    uint256 totalInterestRepaid
  );
  event FixedLoanPositionRemoved(address indexed user, uint256 posId);
  event AllPositionsRepaid(address indexed user, uint256 totalRepaid);

  /// @dev Immutable/state values that the operator paths need. Filled by the broker on each call.
  struct OperatorContext {
    IMoolah moolah;
    address loanToken;
    address wbnb;
    address rateCalculator;
    address relayer;
    Id marketId;
  }

  // =============================================
  //              External entry points
  // =============================================

  /// @dev Implements LendingBroker.repay(amount, onBehalf). Storage refs come from the broker.
  function repayDynamic(
    mapping(address => DynamicLoanPosition) storage dynamicLoanPositions,
    OperatorContext memory ctx,
    uint256 amount,
    address onBehalf
  ) external {
    address user = msg.sender;
    bool isNative;
    (amount, isNative) = _pullPayment(ctx, amount, user);
    if (amount == 0) revert ZeroAmount();
    if (onBehalf == address(0)) revert ZeroAddress();

    DynamicLoanPosition storage position = dynamicLoanPositions[onBehalf];
    uint256 rate = IRateCalculator(ctx.rateCalculator).accrueRate(address(this));
    uint256 accruedInterest = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate).zeroFloorSub(
      position.principal
    );
    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 amountLeft = amount - repayInterestAmt;
    uint256 repayPrincipalAmt = amountLeft > position.principal ? position.principal : amountLeft;
    if (repayInterestAmt + repayPrincipalAmt == 0) revert NothingToRepay();

    uint256 totalRepaid;

    // (1) Repay interest first
    position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
      BrokerMath.normalizeBorrowAmount(repayInterestAmt, rate, false)
    );
    _supplyToMoolahVault(ctx, repayInterestAmt);
    totalRepaid += repayInterestAmt;

    // (2) Repay principal if any
    if (repayPrincipalAmt > 0) {
      uint256 principalRepaid = _repayToMoolah(ctx, onBehalf, repayPrincipalAmt);
      if (principalRepaid > 0) {
        position.principal = position.principal.zeroFloorSub(principalRepaid);
        position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
          BrokerMath.normalizeBorrowAmount(principalRepaid, rate, false)
        );
        totalRepaid += principalRepaid;
      }
      if (position.principal == 0) {
        delete dynamicLoanPositions[onBehalf];
      }
    }

    _refundExcess(ctx, amount - totalRepaid, user, isNative);
    _validateDynamicPosition(dynamicLoanPositions, ctx, onBehalf);
    emit DynamicLoanPositionRepaid(onBehalf, totalRepaid, position.principal);
  }

  /// @dev Implements LendingBroker.repay(amount, posId, onBehalf).
  function repayFixed(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    OperatorContext memory ctx,
    uint256 amount,
    uint256 posId,
    address onBehalf
  ) external {
    address user = msg.sender;
    bool isNative;
    (amount, isNative) = _pullPayment(ctx, amount, user);
    if (amount == 0) revert ZeroAmount();
    if (onBehalf == address(0)) revert ZeroAddress();

    FixedLoanPosition memory position = _getFixedPositionByPosId(fixedLoanPositions, onBehalf, posId);
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(position) - position.interestRepaid;

    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 repayPrincipalAmt = amount - repayInterestAmt;

    if (repayInterestAmt > 0) {
      position.interestRepaid += repayInterestAmt;
      _supplyToMoolahVault(ctx, repayInterestAmt);
    }

    uint256 penalty;
    uint256 principalRepaid;
    if (repayPrincipalAmt > 0) {
      penalty = BrokerMath.getPenaltyForFixedPosition(position, UtilsLib.min(repayPrincipalAmt, remainingPrincipal));
      if (penalty > 0) {
        repayPrincipalAmt -= penalty;
        _supplyToMoolahVault(ctx, penalty);
      }
      uint256 repayablePrincipal = UtilsLib.min(repayPrincipalAmt, remainingPrincipal);
      if (repayablePrincipal > 0) {
        principalRepaid = _repayToMoolah(ctx, onBehalf, repayablePrincipal);
        position.principalRepaid += principalRepaid;
        position.interestRepaid = 0;
        position.lastRepaidTime = block.timestamp;
      }
    }

    if (position.principalRepaid >= position.principal) {
      _removeFixedPositionByPosId(fixedLoanPositions, onBehalf, posId);
    } else {
      _updateFixedPosition(fixedLoanPositions, onBehalf, position);
    }

    _refundExcess(ctx, amount - (repayInterestAmt + penalty + principalRepaid), user, isNative);
    _validateFixedPosition(ctx, position);

    emit RepaidFixedLoanPosition(
      onBehalf,
      posId,
      position.principal,
      position.start,
      position.end,
      position.apr,
      position.principalRepaid,
      principalRepaid,
      repayInterestAmt,
      penalty,
      position.interestRepaid
    );
  }

  /// @dev Implements LendingBroker.repayAll(onBehalf). Charges full early-repay penalty
  ///      on every outstanding fixed position. Caller must send `msg.value >= totalDebt`
  ///      when paying in native BNB; excess is refunded.
  function repayAll(
    mapping(address => DynamicLoanPosition) storage dynamicLoanPositions,
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    OperatorContext memory ctx,
    address onBehalf
  ) external {
    if (onBehalf == address(0)) revert ZeroAddress();
    address user = msg.sender;
    bool isNative = msg.value > 0;

    uint256 rate = IRateCalculator(ctx.rateCalculator).accrueRate(address(this));
    DynamicLoanPosition memory dynPos = dynamicLoanPositions[onBehalf];
    FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[onBehalf];

    (uint256 dynamicInterest, uint256 fixedInterestAndPenalty, uint256 debtAtMoolah, uint256 totalDebt) = BrokerMath
      .previewRepayAllAmounts(onBehalf, dynPos, fixedPositions, rate);
    if (totalDebt == 0) revert NothingToRepay();

    // pull funds
    if (isNative) {
      if (ctx.loanToken != ctx.wbnb) revert NativeNotSupported();
      if (msg.value < totalDebt) revert InsufficientAmount();
      IWBNB(ctx.wbnb).deposit{ value: msg.value }();
    } else {
      IERC20(ctx.loanToken).safeTransferFrom(user, address(this), totalDebt);
    }

    // supply broker revenue (interest + penalty) to the vault
    _supplyToMoolahVault(ctx, dynamicInterest + fixedInterestAndPenalty);

    // repay every Moolah borrow share at once via shares
    Position memory pos = ctx.moolah.position(ctx.marketId, onBehalf);
    if (pos.borrowShares > 0) {
      _repayMoolahByShares(ctx, onBehalf, pos.borrowShares, debtAtMoolah);
    }

    // clear dynamic position
    if (dynPos.principal > 0 || dynamicInterest > 0) {
      delete dynamicLoanPositions[onBehalf];
      emit DynamicLoanPositionRepaid(onBehalf, dynPos.principal + dynamicInterest, 0);
    }

    // emit per-position removal events then wipe the array
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory p = fixedPositions[i];
      if (p.principal > p.principalRepaid) {
        emit FixedLoanPositionRemoved(onBehalf, p.posId);
      }
    }
    delete fixedLoanPositions[onBehalf];

    if (isNative) _refundExcess(ctx, msg.value - totalDebt, user, true);
    emit AllPositionsRepaid(onBehalf, totalDebt);
  }

  // =============================================
  //              Internal helpers
  // =============================================

  function _pullPayment(
    OperatorContext memory ctx,
    uint256 amount,
    address user
  ) internal returns (uint256 finalAmount, bool isNative) {
    isNative = msg.value > 0;
    if (isNative) {
      if (ctx.loanToken != ctx.wbnb) revert NativeNotSupported();
      finalAmount = msg.value;
      IWBNB(ctx.wbnb).deposit{ value: finalAmount }();
    } else {
      IERC20(ctx.loanToken).safeTransferFrom(user, address(this), amount);
      finalAmount = amount;
    }
  }

  function _refundExcess(OperatorContext memory ctx, uint256 excess, address user, bool isNative) internal {
    if (excess == 0) return;
    if (isNative) {
      _unwrapAndSend(ctx, payable(user), excess);
    } else {
      IERC20(ctx.loanToken).safeTransfer(user, excess);
    }
  }

  function _unwrapAndSend(OperatorContext memory ctx, address payable recipient, uint256 amount) internal {
    IWBNB(ctx.wbnb).withdraw(amount);
    (bool ok, ) = recipient.call{ value: amount }("");
    if (!ok) revert NativeTransferFailed();
  }

  function _supplyToMoolahVault(OperatorContext memory ctx, uint256 interest) internal {
    if (interest > 0) {
      IERC20(ctx.loanToken).safeIncreaseAllowance(ctx.relayer, interest);
      IBrokerInterestRelayer(ctx.relayer).supplyToVault(interest);
    }
  }

  function _repayToMoolah(OperatorContext memory ctx, address onBehalf, uint256 amount) internal returns (uint256) {
    Market memory market = ctx.moolah.market(ctx.marketId);
    uint256 amountShares = amount.toSharesDown(market.totalBorrowAssets, market.totalBorrowShares);
    return _repayMoolahByShares(ctx, onBehalf, amountShares, amount);
  }

  function _repayMoolahByShares(
    OperatorContext memory ctx,
    address onBehalf,
    uint256 shares,
    uint256 allowance
  ) internal returns (uint256 assetsRepaid) {
    IERC20(ctx.loanToken).safeIncreaseAllowance(address(ctx.moolah), allowance);
    (assetsRepaid, ) = ctx.moolah.repay(ctx.moolah.idToMarketParams(ctx.marketId), 0, shares, onBehalf, "");
    IERC20(ctx.loanToken).forceApprove(address(ctx.moolah), 0);
  }

  function _getFixedPositionByPosId(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    address user,
    uint256 posId
  ) internal view returns (FixedLoanPosition memory) {
    FixedLoanPosition[] memory positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) return positions[i];
    }
    revert PositionNotFound();
  }

  function _removeFixedPositionByPosId(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    address user,
    uint256 posId
  ) internal {
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        positions[i] = positions[positions.length - 1];
        positions.pop();
        emit FixedLoanPositionRemoved(user, posId);
        return;
      }
    }
    revert PositionNotFound();
  }

  function _updateFixedPosition(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    address user,
    FixedLoanPosition memory position
  ) internal {
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == position.posId) {
        positions[i] = position;
        return;
      }
    }
    revert PositionNotFound();
  }

  function _validateDynamicPosition(
    mapping(address => DynamicLoanPosition) storage dynamicLoanPositions,
    OperatorContext memory ctx,
    address user
  ) internal view {
    uint256 principal = dynamicLoanPositions[user].principal;
    if (principal == 0) return;
    uint256 minLoan = ctx.moolah.minLoan(ctx.moolah.idToMarketParams(ctx.marketId));
    require(principal >= minLoan, "broker/dynamic-below-min-loan");
  }

  function _validateFixedPosition(OperatorContext memory ctx, FixedLoanPosition memory position) internal view {
    uint256 remaining = position.principal - position.principalRepaid;
    if (remaining == 0) return;
    uint256 minLoan = ctx.moolah.minLoan(ctx.moolah.idToMarketParams(ctx.marketId));
    require(remaining >= minLoan, "broker/fixed-below-min-loan");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { FixedLoanPosition, GraceConfig, FixedTermType } from "../interfaces/ICreditBroker.sol";
import { ICreditBrokerInterestRelayer } from "../interfaces/ICreditBrokerInterestRelayer.sol";
import { CreditBrokerMath } from "./CreditBrokerMath.sol";
import { MoolahOperateLib } from "./MoolahOperateLib.sol";

import { Id, IMoolah, MarketParams, Position } from "../../moolah/interfaces/IMoolah.sol";
import { IOracle } from "../../moolah/interfaces/IOracle.sol";
import { UtilsLib } from "../../moolah/libraries/UtilsLib.sol";

/// @title CreditBroker operator library
/// @notice Houses the bytecode for `repay`, `repayInterestWithLista`, and `repayAll` so the
///         broker itself stays under the EIP-170 size limit. Invoked via DELEGATECALL, so all
///         state mutations apply to CreditBroker's storage and events surface from
///         CreditBroker's address.
library CreditBrokerOperatorLib {
  using SafeERC20 for IERC20;

  // ------- Events (must match ICreditBroker signatures so indexers keep working) -------
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
    uint256 totalInterestRepaid,
    bool isBadDebt
  );
  event FixedLoanPositionRemoved(address indexed user, uint256 posId);
  event PaidOffPenalizedPosition(address indexed user, uint256 posId, uint256 paidOffTime);
  event RepayInterestWithLista(
    address indexed user,
    uint256 posId,
    uint256 interestAmount,
    uint256 listaAmount,
    uint256 listaPrice
  );
  event AllPositionsRepaid(address indexed user, uint256 totalRepaid);

  /// @dev Immutable/state values the operator paths need. Filled by the broker on each call.
  struct OperatorContext {
    IMoolah moolah;
    address loanToken;
    address relayer;
    address lista;
    address oracle;
    Id marketId;
    uint256 listaDiscountRate;
    GraceConfig graceConfig;
  }

  // =============================================
  //              External entry points
  // =============================================

  /// @dev Implements CreditBroker.repay(amount, posId, onBehalf). `receivedInterest` is the
  ///      portion of interest already sitting in the broker (funded by the LISTA path).
  function repay(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    OperatorContext memory ctx,
    uint256 amount,
    uint256 posId,
    address onBehalf,
    uint256 receivedInterest
  ) public {
    require(amount > 0, "zero amount");
    require(onBehalf != address(0), "zero address");
    address user = msg.sender;

    // fetch position (will revert if not found)
    FixedLoanPosition memory position = _getFixedPositionByPosId(fixedLoanPositions, onBehalf, posId);

    // check if position is penalized; if so, must pay in full
    if (block.timestamp > position.end + ctx.graceConfig.period) {
      uint256 totalRepayNeeded = CreditBrokerMath.getTotalRepayNeeded(position, ctx.graceConfig);
      require(amount >= totalRepayNeeded, "penalized position must fully repaid");
    }

    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    uint256 remainingInterest = CreditBrokerMath.getInterestForFixedPosition(position) - position.interestRepaid;

    // initialize repay amounts
    uint256 repayInterestAmt = amount < remainingInterest ? amount : remainingInterest;
    uint256 repayPrincipalAmt = amount - repayInterestAmt;

    // repay interest first, it might be zero if user just repaid before
    if (repayInterestAmt > 0) {
      if (repayInterestAmt > receivedInterest) {
        IERC20(ctx.loanToken).safeTransferFrom(user, address(this), repayInterestAmt - receivedInterest);
      }

      // update repaid interest amount
      position.interestRepaid += repayInterestAmt;
      // supply interest into vault as revenue
      MoolahOperateLib.supplyToMoolahVault(ctx.loanToken, ctx.relayer, repayInterestAmt);
    }

    uint256 penalty = 0;
    uint256 principalRepaid = 0;
    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // ----- delay penalty
      // check delay penalty if user is repaying after grace period ends
      // penalty = 15% * debt
      penalty = CreditBrokerMath.getPenaltyForCreditPosition(
        remainingPrincipal,
        remainingInterest,
        position.end,
        ctx.graceConfig
      );

      // supply penalty into vault as revenue
      if (penalty > 0) {
        IERC20(ctx.loanToken).safeTransferFrom(user, address(this), penalty);
        repayPrincipalAmt -= penalty;
        MoolahOperateLib.supplyToMoolahVault(ctx.loanToken, ctx.relayer, penalty);
      }

      // the rest will be used to repay partially
      uint256 repayablePrincipal = UtilsLib.min(repayPrincipalAmt, remainingPrincipal);
      if (repayablePrincipal > 0) {
        if (position.isBadDebt) {
          IERC20(ctx.loanToken).safeTransferFrom(user, address(this), repayablePrincipal);
          MoolahOperateLib.supplyToMoolahVault(ctx.loanToken, ctx.relayer, repayablePrincipal);
          position.principalRepaid += repayablePrincipal;
        } else {
          uint256 repaidShares;
          (principalRepaid, repaidShares) = MoolahOperateLib.repayToMoolah(
            ctx.loanToken,
            address(ctx.moolah),
            ctx.marketId,
            user,
            onBehalf,
            repayablePrincipal
          );
          position.principalRepaid += principalRepaid;
          position.borrowedShares -= repaidShares;
        }
        if (position.termType == FixedTermType.ACCRUE_INTEREST) {
          // reset repaid interest to zero (all accrued interest has been cleared)
          position.interestRepaid = 0;
        }
        // reset last repay time to now
        position.lastRepaidTime = block.timestamp;
      }
    }

    // post repayment
    if (position.principalRepaid >= position.principal) {
      // removes it from user's fixed positions
      _removeFixedPositionByPosId(fixedLoanPositions, onBehalf, posId);
      // log paid off penalized position
      if (penalty > 0) {
        emit PaidOffPenalizedPosition(onBehalf, posId, block.timestamp);
      }
    } else {
      // update position
      _updateFixedPosition(fixedLoanPositions, onBehalf, position);
    }

    // validate only the position this call touched
    _validateFixedPosition(ctx, position);

    // emit event
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
      position.interestRepaid,
      position.isBadDebt
    );
  }

  /// @dev Implements CreditBroker.repayInterestWithLista(...).
  function repayInterestWithLista(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    OperatorContext memory ctx,
    uint256 loanTokenAmount,
    uint256 listaAmount,
    uint256 posId,
    address onBehalf
  ) external {
    require(listaAmount > 0, "zero amount");
    require(IERC20Metadata(ctx.loanToken).decimals() == 18, "decimal mismatch");
    uint256 listaPrice = IOracle(ctx.oracle).peek(ctx.lista);
    uint256 maxListaAmount = CreditBrokerMath.getMaxListaForInterestRepay(
      _getFixedPositionByPosId(fixedLoanPositions, onBehalf, posId),
      listaPrice,
      ctx.listaDiscountRate
    );

    if (listaAmount > maxListaAmount) {
      listaAmount = maxListaAmount;
    }

    // transfer LISTA from msg.sender to Relayer
    IERC20(ctx.lista).safeTransferFrom(msg.sender, ctx.relayer, listaAmount);

    uint256 interestAmount = CreditBrokerMath.getInterestAmountFromLista(
      listaAmount,
      listaPrice,
      ctx.listaDiscountRate
    );

    // transfer interest amount from Relayer to address(this)
    ICreditBrokerInterestRelayer(ctx.relayer).transferLoan(interestAmount);

    // add interest amount to total repay amount
    loanTokenAmount += interestAmount;

    repay(fixedLoanPositions, ctx, loanTokenAmount, posId, onBehalf, interestAmount);

    emit RepayInterestWithLista(onBehalf, posId, interestAmount, listaAmount, listaPrice);
  }

  /// @dev Implements CreditBroker.repayAll(onBehalf): clears every outstanding position of
  ///      `onBehalf` in a single call, charging outstanding interest and any delay penalty.
  /// @notice This is the escape hatch out of the `(0, minLoan)` dead band. A position that fell
  ///         below `minLoan` — because the loan token depegged, or because `minLoanValue` was
  ///         raised — can no longer be partially repaid, so full clearance is the only way out.
  ///         Every position is removed, so no min-loan validation applies, and the Moolah leg
  ///         repays by shares so `borrowShares` lands on exactly zero regardless of how the
  ///         market's assets:shares ratio sits.
  function repayAll(
    mapping(address => FixedLoanPosition[]) storage fixedLoanPositions,
    OperatorContext memory ctx,
    address onBehalf
  ) external {
    require(onBehalf != address(0), "zero address");
    address user = msg.sender;

    // accrue first so `debtAtMoolah` below is exact for this block
    MarketParams memory marketParams = ctx.moolah.idToMarketParams(ctx.marketId);
    ctx.moolah.accrueInterest(marketParams);

    FixedLoanPosition[] memory positions = fixedLoanPositions[onBehalf];
    (uint256 interestAndPenalty, uint256 badDebtPrincipal, uint256 debtAtMoolah, uint256 totalDebt) = CreditBrokerMath
      .previewRepayAllAmounts(onBehalf, positions, ctx.graceConfig, address(ctx.moolah), ctx.marketId);
    require(totalDebt > 0, "nothing to repay");

    // broker revenue (interest + penalty) and written-off principal both settle via the relayer
    uint256 toRelayer = interestAndPenalty + badDebtPrincipal;
    if (toRelayer > 0) {
      IERC20(ctx.loanToken).safeTransferFrom(user, address(this), toRelayer);
      MoolahOperateLib.supplyToMoolahVault(ctx.loanToken, ctx.relayer, toRelayer);
    }

    // clear every Moolah borrow share at once, by shares
    uint256 borrowShares = ctx.moolah.position(ctx.marketId, onBehalf).borrowShares;
    if (borrowShares > 0) {
      MoolahOperateLib.repayToMoolahByShares(
        ctx.loanToken,
        address(ctx.moolah),
        ctx.marketId,
        user,
        onBehalf,
        borrowShares,
        debtAtMoolah
      );
    }

    // emit per-position removal events, then wipe the array
    for (uint256 i = 0; i < positions.length; i++) {
      emit FixedLoanPositionRemoved(onBehalf, positions[i].posId);
    }
    delete fixedLoanPositions[onBehalf];

    emit AllPositionsRepaid(onBehalf, totalDebt);
  }

  // =============================================
  //              Internal helpers
  // =============================================

  /// @dev A position must either be cleared or stay at or above Moolah's minimum loan.
  ///      Only the position a call actually touched is checked: validating the whole array
  ///      would let one stranded position block every other action on the account.
  ///      Bad-debt positions are skipped — liquidation already zeroed their Moolah shares,
  ///      so there is no Moolah-side floor left for them to satisfy.
  function _validateFixedPosition(OperatorContext memory ctx, FixedLoanPosition memory position) internal view {
    if (position.isBadDebt) return;
    uint256 remaining = position.principal - position.principalRepaid;
    if (remaining == 0) return;
    require(remaining >= ctx.moolah.minLoan(ctx.moolah.idToMarketParams(ctx.marketId)), "below min loan");
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
    revert("position not found");
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
    revert("position not found");
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
    revert("position not found");
  }
}

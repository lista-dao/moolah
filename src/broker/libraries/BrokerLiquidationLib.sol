// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UtilsLib } from "../../moolah/libraries/UtilsLib.sol";
import { MathLib, WAD } from "../../moolah/libraries/MathLib.sol";
import { SharesMathLib } from "../../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../../moolah/interfaces/IMoolah.sol";
import { ORACLE_PRICE_SCALE, LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR } from "../../moolah/libraries/ConstantsLib.sol";
import { IBroker, FixedLoanPosition, DynamicLoanPosition, LiquidationContext } from "../interfaces/IBroker.sol";
import { PriceLib } from "../../moolah/libraries/PriceLib.sol";
import { BrokerMath } from "./BrokerMath.sol";

library BrokerLiquidationLib {
  using MathLib for uint128;
  using MathLib for uint256;
  using SharesMathLib for uint256;

  /**
   * @dev Deduct the debt from a dynamic loan position
   * @param position The dynamic loan position to deduct from
   * @param interestToDeduct The amount of interest to deduct
   * @param principalToDeduct The amount of principal to deduct
   * @param rate The current interest rate
   * @return interestToDeduct The remaining amount of interest to deduct
   * @return principalToDeduct The remaining amount of principal to deduct
   * @return position The updated dynamic loan position
   */
  function deductDynamicPositionDebt(
    DynamicLoanPosition memory position,
    uint256 interestToDeduct,
    uint256 principalToDeduct,
    uint256 rate
  ) public returns (uint256, uint256, DynamicLoanPosition memory) {
    // get actual debt
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    if (actualDebt == 0) return (interestToDeduct, principalToDeduct, position);

    uint256 outstandingInterest = UtilsLib.zeroFloorSub(actualDebt, position.principal);

    // clear as much accrued interest as possible
    uint256 interestPaid = UtilsLib.min(outstandingInterest, interestToDeduct);
    if (interestPaid > 0) {
      position.normalizedDebt = UtilsLib.zeroFloorSub(
        position.normalizedDebt,
        BrokerMath.normalizeBorrowAmount(interestPaid, rate)
      );
      interestToDeduct -= interestPaid;
    }

    // reduce principal with whatever is left
    uint256 principalPaid = UtilsLib.min(position.principal, principalToDeduct);
    if (principalPaid > 0) {
      position.principal -= principalPaid;
      position.normalizedDebt = UtilsLib.zeroFloorSub(
        position.normalizedDebt,
        BrokerMath.normalizeBorrowAmount(principalPaid, rate)
      );
      principalToDeduct -= principalPaid;
    }

    return (interestToDeduct, principalToDeduct, position);
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
    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(p) - p.interestRepaid;

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

  /// @dev Preview the liquidation repayment amounts
  /// @dev cloned from Moolah.sol
  function previewLiquidationRepayment(
    MarketParams memory marketParams,
    Market memory market,
    uint256 seizedAssets,
    uint256 repaidShares,
    address user
  ) public view returns (uint256, uint256, uint256) {
    uint256 collateralPrice = getCollateralPrice(marketParams, user);

    // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
    uint256 liquidationIncentiveFactor = UtilsLib.min(
      MAX_LIQUIDATION_INCENTIVE_FACTOR,
      WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
    );

    if (seizedAssets > 0) {
      uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

      repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
        market.totalBorrowAssets,
        market.totalBorrowShares
      );
    } else {
      seizedAssets = repaidShares
        .toAssetsDown(market.totalBorrowAssets, market.totalBorrowShares)
        .wMulDown(liquidationIncentiveFactor)
        .mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
    }
    uint256 repaidAssets = repaidShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

    return (seizedAssets, repaidShares, repaidAssets);
  }

  function getCollateralPrice(MarketParams memory marketParams, address user) internal view returns (uint256) {
    (uint256 basePrice, uint256 quotePrice, uint256 baseTokenDecimals, uint256 quoteTokenDecimals) = PriceLib._getPrice(
      marketParams,
      user,
      address(this)
    );

    uint256 scaleFactor = 10 ** (36 + quoteTokenDecimals - baseTokenDecimals);
    return scaleFactor.mulDivDown(basePrice, quotePrice);
  }
}

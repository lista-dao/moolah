// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { LiquidityAmounts } from "lista-dao-contracts/libraries/LiquidityAmounts.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { IWBNB } from "../interfaces/IWBNB.sol";
import { IStakeManager } from "../interfaces/IStakeManager.sol";

/**
 * @title SlisBnbInventoryLib
 * @author Lista DAO
 * @notice External library holding the (user-invisible) slisBNB inventory-conversion plumbing used
 *         by {SlisBNBV3Provider} during rebalance. Deployed once and linked, so the StakeManager
 *         interaction bytecode lives here instead of inflating the provider implementation.
 *
 * @dev    Invoked via DELEGATECALL, so `address(this)` is the provider: token custody, allowances
 *         and the native BNB received from `instantWithdraw` all resolve to the provider. The
 *         StakeManager / token addresses are passed in as arguments (the provider's constants are
 *         not readable from library code).
 */
library SlisBnbInventoryLib {
  using SafeERC20 for IERC20;

  uint128 internal constant RATIO_SAMPLE_LIQUIDITY = 1e18;
  uint256 internal constant RATE_SCALE = 1e18;

  error OneDirection();
  error NotSlisBnbWbnbPool();

  /// @notice Convert the over-weight leg so free inventory matches the target range's optimal
  ///         token0/token1 injection ratio at the exchange-rate-implied price.
  function convertToOptimalRatio(
    IStakeManager stakeManager,
    address slisBnb,
    address wbnb,
    address token0,
    address token1,
    uint256 total0,
    uint256 total1,
    uint160 exchangeRateSqrtPriceX96,
    int24 targetTickLower,
    int24 targetTickUpper,
    uint256 token1PerToken0Rate
  ) external returns (uint256, uint256) {
    if (total0 == 0 && total1 == 0) return (total0, total1);
    if (token1PerToken0Rate == 0) return (total0, total1);
    if (!((token0 == wbnb && token1 == slisBnb) || (token0 == slisBnb && token1 == wbnb))) {
      revert NotSlisBnbWbnbPool();
    }

    (uint256 target0, uint256 target1) = _targetAmountsForOptimalRatio(
      total0,
      total1,
      exchangeRateSqrtPriceX96,
      TickMath.getSqrtRatioAtTick(targetTickLower),
      TickMath.getSqrtRatioAtTick(targetTickUpper),
      token1PerToken0Rate
    );

    uint256 token0ToToken1;
    uint256 token1ToToken0;
    if (total0 > target0) {
      token0ToToken1 = total0 - target0;
    } else if (target0 > total0) {
      uint256 amountByToken0Shortfall = FullMath.mulDiv(target0 - total0, token1PerToken0Rate, RATE_SCALE);
      uint256 amountByToken1Excess = total1 > target1 ? total1 - target1 : amountByToken0Shortfall;
      token1ToToken0 = amountByToken1Excess > total1 ? total1 : amountByToken1Excess;
    }

    (uint256 bnbToStake, uint256 slisBnbToRedeem) = _conversionAmounts(
      token0,
      token1,
      wbnb,
      token0ToToken1,
      token1ToToken0
    );

    return _convert(stakeManager, slisBnb, wbnb, token0, token1, total0, total1, bnbToStake, slisBnbToRedeem);
  }

  /// @notice Convert free inventory between the WBNB and slisBNB legs and return adjusted totals.
  ///         - `bnbToStake`: unwrap that much WBNB and stake it (deposit) into slisBNB.
  ///         - `slisBnbToRedeem`: instant-redeem that much slisBNB into BNB, re-wrapped to WBNB.
  ///         Goes through the StakeManager at its on-chain exchange rate (not the pool), so it is
  ///         not market-manipulable; instantWithdraw deducts a deterministic fee. Amounts moved are
  ///         measured by balance delta so the returned totals stay exact, and capped to availability.
  function convert(
    IStakeManager stakeManager,
    address slisBnb,
    address wbnb,
    address token0,
    address token1,
    uint256 total0,
    uint256 total1,
    uint256 bnbToStake,
    uint256 slisBnbToRedeem
  ) external returns (uint256, uint256) {
    return _convert(stakeManager, slisBnb, wbnb, token0, token1, total0, total1, bnbToStake, slisBnbToRedeem);
  }

  function _convert(
    IStakeManager stakeManager,
    address slisBnb,
    address wbnb,
    address token0,
    address token1,
    uint256 total0,
    uint256 total1,
    uint256 bnbToStake,
    uint256 slisBnbToRedeem
  ) private returns (uint256, uint256) {
    if (bnbToStake == 0 && slisBnbToRedeem == 0) return (total0, total1);
    if (bnbToStake > 0 && slisBnbToRedeem > 0) revert OneDirection();
    if (!((token0 == wbnb && token1 == slisBnb) || (token0 == slisBnb && token1 == wbnb))) {
      revert NotSlisBnbWbnbPool();
    }
    bool wbnbIs0 = token0 == wbnb;

    if (bnbToStake > 0) {
      uint256 wbnbAvail = wbnbIs0 ? total0 : total1;
      uint256 amt = bnbToStake > wbnbAvail ? wbnbAvail : bnbToStake;
      if (amt > 0) {
        uint256 sBefore = IERC20(slisBnb).balanceOf(address(this));
        IWBNB(wbnb).withdraw(amt);
        stakeManager.deposit{ value: amt }();
        uint256 minted = IERC20(slisBnb).balanceOf(address(this)) - sBefore;
        if (wbnbIs0) {
          total0 -= amt;
          total1 += minted;
        } else {
          total1 -= amt;
          total0 += minted;
        }
      }
    } else {
      uint256 slisAvail = wbnbIs0 ? total1 : total0;
      uint256 amt = slisBnbToRedeem > slisAvail ? slisAvail : slisBnbToRedeem;
      if (amt > 0) {
        uint256 bBefore = address(this).balance;
        IERC20(slisBnb).safeIncreaseAllowance(address(stakeManager), amt);
        stakeManager.instantWithdraw(amt);
        uint256 bnbOut = address(this).balance - bBefore;
        if (bnbOut > 0) IWBNB(wbnb).deposit{ value: bnbOut }();
        if (wbnbIs0) {
          total0 += bnbOut;
          total1 -= amt;
        } else {
          total1 += bnbOut;
          total0 -= amt;
        }
      }
    }
    return (total0, total1);
  }

  function _targetAmountsForOptimalRatio(
    uint256 total0,
    uint256 total1,
    uint160 exchangeRateSqrtPriceX96,
    uint160 sqrtLower,
    uint160 sqrtUpper,
    uint256 token1PerToken0Rate
  ) private pure returns (uint256 target0, uint256 target1) {
    (uint256 ratio0, uint256 ratio1) = LiquidityAmounts.getAmountsForLiquidity(
      exchangeRateSqrtPriceX96,
      sqrtLower,
      sqrtUpper,
      RATIO_SAMPLE_LIQUIDITY
    );

    if (ratio0 == 0) return (0, total1 + FullMath.mulDiv(total0, token1PerToken0Rate, RATE_SCALE));

    uint256 ratio0ValueInToken1 = FullMath.mulDiv(ratio0, token1PerToken0Rate, RATE_SCALE);
    uint256 denominator = ratio0ValueInToken1 + ratio1;
    if (denominator == 0) return (total0, total1);

    uint256 totalValueInToken1 = total1 + FullMath.mulDiv(total0, token1PerToken0Rate, RATE_SCALE);
    target0 = FullMath.mulDiv(totalValueInToken1, ratio0, denominator);
    uint256 target0ValueInToken1 = FullMath.mulDiv(target0, token1PerToken0Rate, RATE_SCALE);
    target1 = totalValueInToken1 > target0ValueInToken1 ? totalValueInToken1 - target0ValueInToken1 : 0;
  }

  function _conversionAmounts(
    address token0,
    address token1,
    address wbnb,
    uint256 token0ToToken1,
    uint256 token1ToToken0
  ) private pure returns (uint256 bnbToStake, uint256 slisBnbToRedeem) {
    if (token0ToToken1 > 0) {
      if (token0 == wbnb) bnbToStake = token0ToToken1;
      else slisBnbToRedeem = token0ToToken1;
    } else if (token1ToToken0 > 0) {
      if (token1 == wbnb) bnbToStake = token1ToToken0;
      else slisBnbToRedeem = token1ToToken0;
    }
  }
}

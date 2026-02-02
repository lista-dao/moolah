// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MarketParams, IMoolah, Id, Market } from "../../moolah/interfaces/IMoolah.sol";
import { ICreditBrokerInterestRelayer } from "../interfaces/ICreditBrokerInterestRelayer.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SharesMathLib } from "../../moolah/libraries/SharesMathLib.sol";

library MoolahOperateLib {
  using SafeERC20 for IERC20;
  using SharesMathLib for uint256;
  /**
   * @dev Borrow an amount on behalf of a user from Moolah
   * @param loanToken The address of the loan token
   * @param moolah The address of the Moolah contract
   * @param marketId The market id to borrow
   * @param onBehalf The address of the user to borrow on behalf of
   * @param amount The amount to borrow
   */
  function borrowFromMoolah(
    address loanToken,
    address moolah,
    Id marketId,
    address onBehalf,
    uint256 amount
  ) public returns (uint256 borrowShares) {
    MarketParams memory marketParams = _getMarketParams(moolah, marketId);
    // pre-balance
    uint256 preBalance = IERC20(loanToken).balanceOf(address(this));
    // borrow from moolah with zero interest
    (, borrowShares) = IMoolah(moolah).borrow(marketParams, amount, 0, onBehalf, address(this));
    // should increase the loan balance same as borrowed amount
    require(IERC20(loanToken).balanceOf(address(this)) - preBalance == amount, "invalid borrowed amount");
  }

  /**
   * @dev Repay an amount on behalf of a user to Moolah
   * @param loanToken The address of the loan token
   * @param moolah The address of the Moolah contract
   * @param marketId The market id to repay
   * @param payer The address of the user who pays for the repayment
   * @param onBehalf The address of the user to repay on behalf of
   * @param amount The amount to repay
   */
  function repayToMoolah(
    address loanToken,
    address moolah,
    Id marketId,
    address payer,
    address onBehalf,
    uint256 amount
  ) public returns (uint256 assetsRepaid, uint256 sharesRepaid) {
    IERC20(loanToken).safeTransferFrom(payer, address(this), amount);
    IERC20(loanToken).safeIncreaseAllowance(moolah, amount);

    Market memory market = IMoolah(moolah).market(marketId);
    // convert amount to shares
    uint256 amountShares = amount.toSharesDown(market.totalBorrowAssets, market.totalBorrowShares);
    // using `shares` to ensure full repayment
    (assetsRepaid, sharesRepaid) = IMoolah(moolah).repay(
      _getMarketParams(moolah, marketId),
      0,
      amountShares,
      onBehalf,
      ""
    );
    // refund any excess amount to payer
    if (amount > assetsRepaid) {
      IERC20(loanToken).safeTransfer(payer, amount - assetsRepaid);
    }
  }

  /**
   * @dev Supply an amount of interest to Moolah
   * @param loanToken The address of the loan token
   * @param relayer The address of the interest relayer
   * @param interest The amount of interest to supply
   */
  function supplyToMoolahVault(address loanToken, address relayer, uint256 interest) public {
    if (interest > 0) {
      // approve to relayer
      IERC20(loanToken).safeIncreaseAllowance(relayer, interest);
      // supply interest to relayer to be deposited into vault
      ICreditBrokerInterestRelayer(relayer).supplyToVault(interest);
    }
  }

  function _getMarketParams(address moolah, Id _id) internal view returns (MarketParams memory) {
    return IMoolah(moolah).idToMarketParams(_id);
  }
}

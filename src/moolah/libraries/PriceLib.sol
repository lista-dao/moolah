// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MarketParams } from "../interfaces/IMoolah.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IBrokerBase } from "../../broker/interfaces/IBroker.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library PriceLib {

  /// @dev Returns the price of the collateral asset in terms of the loan asset
  /// @notice if there is a broker for the market and user address is non-zero
  ///         will return a price which might deviates from the market price according to user's position
  /// @param marketParams The market parameters
  /// @param user The user address
  /// @param broker The broker address
  /// @return basePrice The price of the collateral asset
  /// @return quotePrice The price of the loan asset
  /// @return baseTokenDecimals The decimals of the collateral asset
  /// @return quoteTokenDecimals The decimals of the loan asset
  function _getPrice(
    MarketParams memory marketParams,
    address user,
    address broker
  ) public view returns (
    uint256 basePrice,
    uint256 quotePrice,
    uint256 baseTokenDecimals,
    uint256 quoteTokenDecimals
) {
    IOracle _oracle = IOracle(marketParams.oracle);
    baseTokenDecimals = IERC20Metadata(marketParams.collateralToken).decimals();
    quoteTokenDecimals = IERC20Metadata(marketParams.loanToken).decimals();
    basePrice = _oracle.peek(marketParams.collateralToken);
    quotePrice = _oracle.peek(marketParams.loanToken);

    // if market has broker and user address is non-zero
    if (broker != address(0) && user != address(0)) {
      // get price from broker
      // price deviatiates with user's position at broker
      IBrokerBase _broker = IBrokerBase(broker);
      basePrice = _broker.peek(marketParams.collateralToken, user);
      quotePrice = _broker.peek(marketParams.loanToken, user);
    }
   }
}
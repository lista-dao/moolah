// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MarketParams } from "../interfaces/IMoolah.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IBrokerBase } from "../../broker/interfaces/IBroker.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library PriceLib {
  function _getPrice(
    MarketParams memory marketParams,
    address user,
    address broker
  ) public view returns (
    uint256 basePrice,
    uint256 quotePrice,
    uint256 baseTokenDecimals,
    uint256 quotaTokenDecimals
) {
    IOracle _oracle = IOracle(marketParams.oracle);
    baseTokenDecimals = IERC20Metadata(marketParams.collateralToken).decimals();
    quotaTokenDecimals = IERC20Metadata(marketParams.loanToken).decimals();
    basePrice = _oracle.peek(marketParams.collateralToken);
    quotePrice = _oracle.peek(marketParams.loanToken);

    // if market has broker and user address is non-zero
    if (broker != address(0) && user != address(0)) {
      // get price from broker
      // price deviatiates with user's position at broker
      IBrokerBase _broker = IBrokerBase(broker);
      basePrice = _broker.peek(marketParams.collateralToken, user);
      quotePrice = _broker.peek(marketParams.loanToken, user);
    } else {
      basePrice = _oracle.peek(marketParams.collateralToken);
      quotePrice = _oracle.peek(marketParams.loanToken);
    }
   }
}
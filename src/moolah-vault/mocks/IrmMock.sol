// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IIrm } from "moolah/interfaces/IIrm.sol";
import { MarketParams, Market } from "moolah/interfaces/IMoolah.sol";

import { MathLib } from "moolah/libraries/MathLib.sol";

contract IrmMock is IIrm {
  using MathLib for uint128;

  uint256 public apr;

  function setApr(uint256 newApr) external {
    apr = newApr;
  }

  function borrowRateView(MarketParams memory, Market memory) public view returns (uint256) {
    return apr / 365 days;
  }

  function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
    return borrowRateView(marketParams, market);
  }
}

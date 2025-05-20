//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILinearDiscountOracle {
  function PT() external view returns (address);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function decimals() external pure returns (uint8);

  function getDiscount(uint256 timeLeft) external view returns (uint256);
}

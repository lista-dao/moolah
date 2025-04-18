//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

enum PTOracleType {
  NONE,
  LINEAR_DISCOUNT,
  TWAP
}

struct PTOracleConfig {
  PTOracleType oracleType;
  address oracleAddress;
}

interface ILinearDiscountOracle {
  function PT() external view returns (address);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function decimals() external pure returns (uint8);

  function getDiscount(uint256 timeLeft) external view returns (uint256);
}

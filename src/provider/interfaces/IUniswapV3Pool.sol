// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Minimal interface for Uniswap V3 / PancakeSwap V3 pool
interface IUniswapV3Pool {
  function token0() external view returns (address);

  function token1() external view returns (address);

  function fee() external view returns (uint24);

  /// @return sqrtPriceX96 Current sqrt price as Q64.96
  /// @return tick Current tick
  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      uint32 feeProtocol,
      bool unlocked
    );

  /// @param secondsAgos Array of seconds in the past to query
  /// @return tickCumulatives Cumulative tick values for each secondsAgo
  /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds-per-liquidity for each secondsAgo
  function observe(
    uint32[] calldata secondsAgos
  ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

  /// @notice Swap token0 for token1, or token1 for token0
  /// @param recipient Address to receive the output tokens
  /// @param zeroForOne True if swapping token0 → token1, false if token1 → token0
  /// @param amountSpecified Exact input (positive) or exact output (negative)
  /// @param sqrtPriceLimitX96 Price limit; use MIN_SQRT_RATIO+1 for zeroForOne, MAX_SQRT_RATIO-1 otherwise
  /// @param data Arbitrary data forwarded to the swap callback
  function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
  ) external returns (int256 amount0, int256 amount1);
}

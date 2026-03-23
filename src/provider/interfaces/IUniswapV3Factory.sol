// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Minimal interface for Uniswap V3 / PancakeSwap V3 factory
interface IUniswapV3Factory {
  /// @notice Returns the pool address for a given token pair and fee tier, or address(0) if none.
  function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

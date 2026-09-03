// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Uniswap V2 style pair interface. The pair is itself the LP token.
interface IListaV2Pair {
  function token0() external view returns (address);

  function token1() external view returns (address);

  function totalSupply() external view returns (uint256);

  function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

  /// @dev Burns the LP held by the pair and sends the underlying to `to`. Transfer LP in first.
  function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

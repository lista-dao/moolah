// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Uniswap V2 style factory interface.
interface IListaV2Factory {
  /// @dev Recipient of the protocol fee LP minted by the pairs of this factory
  function feeTo() external view returns (address);

  function getPair(address tokenA, address tokenB) external view returns (address pair);
}

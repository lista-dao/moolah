// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IWbETH {
  /// @notice ETH per 1 wbETH (1e18). Binance operator-reported exchange rate — monotonic, not market
  ///         driven. This is directly the WETH-per-wbETH rate (no intermediate peg).
  function exchangeRate() external view returns (uint256);
}

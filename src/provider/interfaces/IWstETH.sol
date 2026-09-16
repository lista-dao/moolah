// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IWstETH {
  /// @notice stETH per 1 wstETH (1e18). Lido's on-chain accounting rate — monotonic, not market
  ///         driven. stETH is treated 1:1 with ETH, so this equals the WETH-per-wstETH rate.
  function stEthPerToken() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IV3DexAdapter } from "./IV3DexAdapter.sol";

/**
 * @title ISlisBNBV3DexAdapter
 * @notice slisBNB/BNB adapter surface consumed by SlisBNBV3Provider: the rate-centered rebalance
 *         (forwarded from the provider's BOT-gated call) plus the rate-drift state/config.
 */
interface ISlisBNBV3DexAdapter is IV3DexAdapter {
  function lastCenterRate() external view returns (uint256);

  function centerRateThresholdBps() external view returns (uint256);

  function setCenterRateThresholdBps(uint256 centerRateThresholdBps) external;

  /// @notice Recenter to the exchange-rate-derived range and convert inventory to the optimal ratio.
  ///         onlyProvider — the provider gates the caller with the BOT role.
  function rebalance(uint256 minAmount0, uint256 minAmount1, uint256 minLiquidity, uint256 deadline) external;
}

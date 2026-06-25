// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IV3DexAdapter } from "./IV3DexAdapter.sol";

/**
 * @title ISlisBNBV3DexAdapter
 * @notice slisBNB/BNB adapter surface consumed by SlisBNBV3Provider. The rate-centered `rebalance`
 *         and rate-drift config are now generic (promoted to {IV3DexAdapter}); this alias is retained
 *         so existing imports / casts keep compiling unchanged.
 */
interface ISlisBNBV3DexAdapter is IV3DexAdapter {}

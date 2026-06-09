// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IOracle } from "moolah/interfaces/IOracle.sol";

/**
 * @title IV3ProviderOracle
 * @author Lista DAO
 * @notice Standalone oracle for the vLP share token. Moolah's `market.oracle` points here. It prices
 *         the share by staticcalling the adapter's fair composition view (no double-hop through the
 *         vault), pricing each leg via the resilient oracle, then applying a conservative haircut.
 *         Separating the IOracle implementation from the vault isolates the estimation-bug radius from
 *         vault state and upgrades (Codex adv #5).
 *
 * @dev `peek(share)` reverts on a zero underlying price / zero total value when supply > 0 (finding D),
 *      so Moolah never prices collateral off a broken feed; `supply == 0` returns 0 (pre-market).
 *      `getTokenConfig(share)` self-registers this oracle for the share token; other tokens delegate to
 *      the resilient oracle.
 */
interface IV3ProviderOracle is IOracle {
  /// @notice The DEX adapter whose fair composition view backs share pricing.
  function ADAPTER() external view returns (address);

  /// @notice The vLP share token (the V3Provider) this oracle prices.
  function PROVIDER_SHARE() external view returns (address);

  /// @notice Conservative haircut applied to the share price, in basis points (e.g. 50 = 0.5%).
  function haircutBps() external view returns (uint256);

  /// @notice Set the share-price haircut (MANAGER). Bounded; reverts above the configured cap.
  function setHaircutBps(uint256 haircutBps) external;
}

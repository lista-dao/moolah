// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IOracle } from "moolah/interfaces/IOracle.sol";

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IV3Provider } from "../interfaces/IV3Provider.sol";

/**
 * @title StableV3DexAdapter
 * @author Lista DAO
 * @notice Pair-agnostic {V3DexAdapter} for stable pairs. With no redemption rate to anchor on, it derives
 *         token1-per-token0 from the resilient oracle. Using that as the rate (instead of the base's
 *         rate == 0 TWAP branch) keeps every rate-anchored guard live.
 */
contract StableV3DexAdapter is V3DexAdapter {
  error OracleZero();
  error OracleMismatch();

  /// @dev Held here, not read from the vault: initialize() needs the rate before the vault is wired.
  ///      setProvider cross-checks it against the vault's (immutable) oracle.
  address public immutable RESILIENT_ORACLE;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod,
    address _wrappedNative,
    address _resilientOracle
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod, _wrappedNative) {
    if (_resilientOracle == address(0)) revert ZeroAddress();
    RESILIENT_ORACLE = _resilientOracle;
  }

  /// @dev Size the margins and the spot gate off the pool's measured tick distribution; LST defaults do
  ///      not carry over. A spot gate wider than the range is dead: an out-of-range spot parks idle anyway.
  function initialize(
    address _admin,
    address _manager,
    uint256 _rangeLowerBps,
    uint256 _rangeUpperBps,
    uint256 _maxSpotDeviationBps
  ) external initializer {
    __V3DexAdapter_init(_admin, _manager, _rangeLowerBps, _rangeUpperBps);
    if (_maxSpotDeviationBps > BPS) revert InvalidThreshold();
    maxSpotDeviationBps = _maxSpotDeviationBps;
    emit MaxSpotDeviationBpsChanged(_maxSpotDeviationBps);
    // At 0 the anti-churn guard reads "never centred" and no-ops.
    lastCenterRate = _lstNativeRate();
    centerRateThresholdBps = 1;
  }

  /* ───────────────────────── hook overrides ───────────────────────── */

  /// @dev A vault on a different oracle would price the share off a basis the range never sees.
  function _validateProvider(address _provider) internal view override {
    if (IV3Provider(_provider).resilientOracle() != RESILIENT_ORACLE) revert OracleMismatch();
  }

  /// @dev token1-per-token0 (1e18). The base adjusts for decimals. Fails closed on a zero feed.
  function _lstNativeRate() internal view override returns (uint256) {
    uint256 price0 = IOracle(RESILIENT_ORACLE).peek(TOKEN0);
    uint256 price1 = IOracle(RESILIENT_ORACLE).peek(TOKEN1);
    if (price0 == 0 || price1 == 0) revert OracleZero();
    return (price0 * 1e18) / price1;
  }
}

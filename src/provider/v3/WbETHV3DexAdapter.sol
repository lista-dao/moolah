// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IWbETH } from "../interfaces/IWbETH.sol";

/**
 * @title WbETHV3DexAdapter
 * @author Lista DAO
 * @notice wbETH/WETH specialization of {V3DexAdapter} for Ethereum — mechanism identical to
 *         {WstETHV3DexAdapter}, only the rate source + pair differ. The base carries the rate-centered
 *         range, the rebalance skeleton and the DEX-agnostic, backend-built swap conversion + swap-pair
 *         whitelist. This subclass supplies only:
 *           - _lstNativeRate(): Binance `wbETH.exchangeRate()` (ETH per wbETH ⇒ WETH-per-wbETH);
 *           - fairSqrtPriceX96(): valuation price = pool TWAP CLAMPED to the rate.
 *         `receive()` is inherited: it accepts native ETH only from the WETH unwrap.
 */
contract WbETHV3DexAdapter is V3DexAdapter {
  /* ─────────────────────────── constants ──────────────────────────── */

  address public constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  /// @dev Hard cap on the configurable TWAP-vs-rate valuation clamp band (10%).
  uint256 public constant MAX_TWAP_DEVIATION_BPS = 1_000;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Max |TWAP − rate| band (BPS) for the valuation price: the LP composition is priced at the
  ///      pool TWAP, CLAMPED into [rate·(1−dev), rate·(1+dev)] so a manipulated TWAP cannot move the
  ///      valuation beyond this guardrail. Defaults to the ±range width. 0 ⇒ pure rate-implied.
  uint256 public maxTwapDeviationBps;

  /* ─────────────────────────── events/errors ──────────────────────── */

  event MaxTwapDeviationChanged(uint256 maxTwapDeviationBps);

  error NotWbEthWethPair();
  error InvalidDeviation();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod, WETH) {
    // wbETH/WETH-ONLY: the rate-implied valuation and ±1% tick centering assume token0 == wbETH and
    // token1 == WETH. The base enforces token0 < token1, and wbETH < WETH, so this is the only valid
    // ordering — reject anything else.
    if (!(_token0 == WBETH && _token1 == WETH)) revert NotWbEthWethPair();
  }

  /**
   * @param _admin   Default admin (upgrade / roles).
   * @param _manager Manager role (sets the clamp band + swap-pair whitelist).
   */
  function initialize(address _admin, address _manager) external initializer {
    uint256 initialCenterRate = _lstNativeRate();
    (int24 initialTickLower, int24 initialTickUpper) = _initialTickRange(initialCenterRate);
    __V3DexAdapter_init(_admin, _manager, initialTickLower, initialTickUpper);

    lastCenterRate = initialCenterRate;
    centerRateThresholdBps = INITIAL_RANGE_BPS;
    maxTwapDeviationBps = INITIAL_RANGE_BPS; // default valuation clamp band = ±range width (±1%)
    emit MaxTwapDeviationChanged(INITIAL_RANGE_BPS);
  }

  /* ───────────────────────── manager config ───────────────────────── */

  /// @notice Set the TWAP-vs-rate clamp band (BPS) for the valuation price. 0 ⇒ pure rate-implied.
  function setMaxTwapDeviationBps(uint256 _maxTwapDeviationBps) external onlyRole(MANAGER) {
    if (_maxTwapDeviationBps > MAX_TWAP_DEVIATION_BPS) revert InvalidDeviation();
    maxTwapDeviationBps = _maxTwapDeviationBps;
    emit MaxTwapDeviationChanged(_maxTwapDeviationBps);
  }

  /* ───────────────────────── hook overrides ───────────────────────── */

  /// @dev WETH-per-wbETH (1e18) from Binance's operator-reported exchange rate. Monotonic, not
  ///      market-driven — manipulation-resistant.
  function _lstNativeRate() internal view override returns (uint256) {
    return IWbETH(WBETH).exchangeRate();
  }

  /// @notice Valuation price for the LP composition: the pool TWAP, CLAMPED into
  ///         [rate·(1−dev), rate·(1+dev)] — see {WstETHV3DexAdapter}. dev == 0 ⇒ pure rate-implied.
  function fairSqrtPriceX96() public view override returns (uint160) {
    uint256 rate = _lstNativeRate();
    uint256 dev = maxTwapDeviationBps;

    if (dev == 0) return _sqrtPriceX96FromRate(rate);

    uint160 sqrtLow = _sqrtPriceX96FromRate((rate * (BPS - dev)) / BPS);
    uint160 sqrtHigh = _sqrtPriceX96FromRate((rate * (BPS + dev)) / BPS);
    uint160 twapSqrt = TickMath.getSqrtRatioAtTick(_twapTick());
    if (twapSqrt < sqrtLow) return sqrtLow;
    if (twapSqrt > sqrtHigh) return sqrtHigh;
    return twapSqrt;
  }
}

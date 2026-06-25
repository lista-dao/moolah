// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IWstETH } from "../interfaces/IWstETH.sol";
import { SwapInventoryLib } from "../libraries/SwapInventoryLib.sol";

/**
 * @title WstETHV3DexAdapter
 * @author Lista DAO
 * @notice wstETH/WETH specialization of {V3DexAdapter} for Ethereum. Supplies the LST-specific hooks:
 *           - _lstNativeRate(): Lido `wstETH.stEthPerToken()` (stETH≈ETH 1:1 ⇒ WETH-per-wstETH);
 *           - fairSqrtPriceX96(): valuation price = pool TWAP CLAMPED to the rate, so the oracle/vault
 *             price the LP composition at the (manipulation-bounded) market price;
 *           - _convertToOptimalRatio(): DEX-agnostic, backend-built rebalance swap (à la {Liquidator}).
 *             The BOT backend supplies (swapPair, sellToken0, amountIn, amountOutMin, innerSwapData);
 *             the adapter only allows a whitelisted `swapPair` and bounds the swap by the allowance +
 *             the backend's `amountOutMin` (enforced on the measured output). No on-chain instant
 *             LST→ETH redeem exists, so inventory is converted by a market swap.
 *         `receive()` is inherited: it accepts native ETH only from the WETH unwrap (no StakeManager).
 */
contract WstETHV3DexAdapter is V3DexAdapter {
  /* ─────────────────────────── constants ──────────────────────────── */

  address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  /// @dev Hard cap on the configurable TWAP-vs-rate valuation clamp band (10%).
  uint256 public constant MAX_TWAP_DEVIATION_BPS = 1_000;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Whitelisted swap venues for rebalance conversions (any DEX / aggregator). The backend builds
  ///      the calldata; the adapter only allows whitelisted targets — like {Liquidator}'s pairWhitelist.
  mapping(address => bool) public swapPairWhitelist;

  /// @dev Max |TWAP − rate| band (BPS) for the valuation price: the LP composition is priced at the
  ///      pool TWAP, CLAMPED into [rate·(1−dev), rate·(1+dev)] so a manipulated TWAP cannot move the
  ///      valuation beyond this guardrail. Defaults to the ±range width. 0 ⇒ pure rate-implied.
  uint256 public maxTwapDeviationBps;

  /* ─────────────────────────── events/errors ──────────────────────── */

  event SwapPairWhitelistSet(address indexed swapPair, bool status);
  event MaxTwapDeviationChanged(uint256 maxTwapDeviationBps);

  error NotWstEthWethPair();
  error InvalidDeviation();
  error NotWhitelistedPair();
  error InvalidSwapPair();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod, WETH) {
    // wstETH/WETH-ONLY: the rate-implied valuation, ±1% tick centering and the swap-based inventory
    // conversion all assume token0 == wstETH and token1 == WETH. The base enforces token0 < token1,
    // and wstETH < WETH, so this is the only valid ordering — reject anything else.
    if (!(_token0 == WSTETH && _token1 == WETH)) revert NotWstEthWethPair();
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

  /// @notice Whitelist (or remove) a swap venue the rebalance may call. Backend-built calldata can only
  ///         target whitelisted venues.
  function setSwapPairWhitelist(address swapPair, bool status) external onlyRole(MANAGER) {
    if (swapPair == address(0)) revert ZeroAddress();
    // Defense-in-depth: a swap venue must never be a token / pool / NPM the adapter holds or trusts,
    // else crafted swapData could move the adapter's own inventory (e.g. TOKEN0.transfer) or position.
    if (
      status && (swapPair == TOKEN0 || swapPair == TOKEN1 || swapPair == POOL || swapPair == address(POSITION_MANAGER))
    ) revert InvalidSwapPair();
    swapPairWhitelist[swapPair] = status;
    emit SwapPairWhitelistSet(swapPair, status);
  }

  /// @notice Set the TWAP-vs-rate clamp band (BPS) for the valuation price. 0 ⇒ pure rate-implied.
  function setMaxTwapDeviationBps(uint256 _maxTwapDeviationBps) external onlyRole(MANAGER) {
    if (_maxTwapDeviationBps > MAX_TWAP_DEVIATION_BPS) revert InvalidDeviation();
    maxTwapDeviationBps = _maxTwapDeviationBps;
    emit MaxTwapDeviationChanged(_maxTwapDeviationBps);
  }

  /* ───────────────────────── hook overrides ───────────────────────── */

  /// @dev WETH-per-wstETH (1e18) from Lido's on-chain accounting (stETH≈ETH 1:1). Monotonic, not
  ///      market-driven — manipulation-resistant.
  function _lstNativeRate() internal view override returns (uint256) {
    return IWstETH(WSTETH).stEthPerToken();
  }

  /// @notice Valuation price for the LP composition: the pool TWAP, CLAMPED into
  ///         [rate·(1−dev), rate·(1+dev)]. The oracle and the vault both read this, so they price the
  ///         position at the same (manipulation-bounded) market price; the token split tracks real
  ///         in-range drift between rebalances while the rate clamp bounds any TWAP manipulation.
  ///         Components are valued at the resilient oracle's rate-derived prices (WETH=ETH, wstETH=rate);
  ///         the stETH/ETH depeg is intentionally NOT priced here (carried by a lower LLTV). dev == 0 ⇒
  ///         pure rate-implied (no pool observe()/cardinality dependency).
  function fairSqrtPriceX96() public view override returns (uint160) {
    uint256 rate = _lstNativeRate();
    uint256 dev = maxTwapDeviationBps;

    // dev == 0 ⇒ pure rate-implied: skip the TWAP read entirely, so the valuation has no pool
    // observe()/observation-cardinality dependency.
    if (dev == 0) return _sqrtPriceX96FromRate(rate);

    uint160 sqrtLow = _sqrtPriceX96FromRate((rate * (BPS - dev)) / BPS);
    uint160 sqrtHigh = _sqrtPriceX96FromRate((rate * (BPS + dev)) / BPS);
    uint160 twapSqrt = TickMath.getSqrtRatioAtTick(_twapTick());
    if (twapSqrt < sqrtLow) return sqrtLow;
    if (twapSqrt > sqrtHigh) return sqrtHigh;
    return twapSqrt;
  }

  /// @dev DEX-agnostic, backend-built rebalance conversion. `swapData` (when non-empty) ABI-encodes
  ///      (address swapPair, bool sellToken0, uint256 amountIn, uint256 amountOutMin, bytes innerSwapData):
  ///      the adapter requires `swapPair` whitelisted and forwards `innerSwapData` via a low-level call,
  ///      bounding the swap by the allowance + `amountOutMin` (see {SwapInventoryLib}). Empty swapData ⇒
  ///      recenter without converting inventory.
  function _convertToOptimalRatio(
    uint256 total0,
    uint256 total1,
    int24 /* targetTickLower */,
    int24 /* targetTickUpper */,
    uint256 /* rate */,
    bytes calldata swapData
  ) internal override returns (uint256, uint256) {
    if (swapData.length == 0) return (total0, total1);
    (address swapPair, bool sellToken0, uint256 amountIn, uint256 amountOutMin, bytes memory inner) = abi.decode(
      swapData,
      (address, bool, uint256, uint256, bytes)
    );
    if (!swapPairWhitelist[swapPair]) revert NotWhitelistedPair();
    return SwapInventoryLib.swap(swapPair, TOKEN0, TOKEN1, sellToken0, amountIn, amountOutMin, inner, total0, total1);
  }
}

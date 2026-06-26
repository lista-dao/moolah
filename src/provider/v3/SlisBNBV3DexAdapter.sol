// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IStakeManager } from "../interfaces/IStakeManager.sol";
import { ISlisBNBV3DexAdapter } from "../interfaces/ISlisBNBV3DexAdapter.sol";
import { SlisBnbInventoryLib } from "../libraries/SlisBnbInventoryLib.sol";

/**
 * @title SlisBNBV3DexAdapter
 * @author Lista DAO
 * @notice slisBNB/BNB specialization of {V3DexAdapter}. The base carries the rate-implied fair price,
 *         ±1% rate-centered tick range and the rebalance skeleton; this subclass supplies only the
 *         slisBNB-specific hooks:
 *           - _lstNativeRate(): StakeManager slisBNB↔BNB rate (not pool spot/TWAP);
 *           - _convertToOptimalRatio(): StakeManager stake / instantWithdraw inventory conversion;
 *           - receive(): also accept native BNB from StakeManager.instantWithdraw.
 */
contract SlisBNBV3DexAdapter is V3DexAdapter, ISlisBNBV3DexAdapter {
  /* ─────────────────────────── constants ──────────────────────────── */

  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  IStakeManager public constant STAKE_MANAGER = IStakeManager(0x1adB950d8bB3dA4bE104211D5AB038628e477fE6);

  /// @dev BSC wrapped native token (forwarded to the base as WRAPPED_NATIVE).
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  /// @dev Hard cap on the rebalance instant-withdraw slippage tolerance (10%).
  uint256 public constant MAX_INSTANT_WITHDRAW_SLIPPAGE_BPS = 1_000;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Max tolerated shortfall (BPS) of the rebalance instantWithdraw BNB output vs the StakeManager
  ///      exchange-rate value of the redeemed slisBNB. Bounds the instant-withdraw fee / any rate
  ///      anomaly; the conversion reverts if the realized BNB falls below this rate-anchored floor.
  uint256 public instantWithdrawSlippageBps;

  /* ───────────────────────────── events ───────────────────────────── */

  event InstantWithdrawSlippageChanged(uint256 instantWithdrawSlippageBps);

  /* ───────────────────────────── errors ───────────────────────────── */

  error NotSlisBnbWbnbPair();
  error InvalidSlippage();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod, WBNB) {
    // slisBNB/BNB-ONLY: the rate-implied fair price, ±1% tick centering and StakeManager inventory
    // conversion all assume token0 == slisBNB and token1 == WBNB. The base already enforces
    // token0 < token1, and slisBNB < WBNB, so this is the only valid ordering — reject anything else.
    if (!(_token0 == SLISBNB && _token1 == WBNB)) revert NotSlisBnbWbnbPair();
  }

  /**
   * @param _admin   Default admin (upgrade / roles).
   * @param _manager Manager role (sets centerRateThresholdBps + instantWithdrawSlippageBps).
   */
  function initialize(address _admin, address _manager) external initializer {
    uint256 initialCenterRate = _lstNativeRate();
    (int24 initialTickLower, int24 initialTickUpper) = _initialTickRange(initialCenterRate);
    __V3DexAdapter_init(_admin, _manager, initialTickLower, initialTickUpper);
    lastCenterRate = initialCenterRate;
    centerRateThresholdBps = INITIAL_RANGE_BPS;
    instantWithdrawSlippageBps = 100; // default 1% tolerance; MANAGER tunes to the live fee + buffer
    emit InstantWithdrawSlippageChanged(100);
  }

  /* ───────────────────────── manager config ───────────────────────── */

  /// @notice Set the rebalance instant-withdraw slippage tolerance (BPS). 0 ⇒ require the full
  ///         rate value (no fee tolerated). onlyRole MANAGER.
  function setInstantWithdrawSlippageBps(uint256 _instantWithdrawSlippageBps) external onlyRole(MANAGER) {
    if (_instantWithdrawSlippageBps > MAX_INSTANT_WITHDRAW_SLIPPAGE_BPS) revert InvalidSlippage();
    instantWithdrawSlippageBps = _instantWithdrawSlippageBps;
    emit InstantWithdrawSlippageChanged(_instantWithdrawSlippageBps);
  }

  /* ───────────────────────── hook overrides ───────────────────────── */

  /// @dev slisBNB↔BNB rate from the StakeManager (1e18). 0 for any non-slisBNB/WBNB pair → base TWAP.
  function _lstNativeRate() internal view override returns (uint256) {
    return _isSlisBnbWbnbPool() ? _poolPriceRate() : 0;
  }

  /// @dev Convert pooled inventory to the optimal ratio via StakeManager stake (WBNB→slisBNB) /
  ///      instantWithdraw (slisBNB→BNB→WBNB).
  function _convertToOptimalRatio(
    uint256 total0,
    uint256 total1,
    int24 targetTickLower,
    int24 targetTickUpper,
    uint256 rate,
    bytes calldata /* swapData */
  ) internal override returns (uint256, uint256) {
    if (!_isSlisBnbWbnbPool()) return (total0, total1);
    return
      SlisBnbInventoryLib.convertToOptimalRatio(
        STAKE_MANAGER,
        SLISBNB,
        WBNB,
        TOKEN0,
        TOKEN1,
        total0,
        total1,
        _sqrtPriceX96FromRate(rate),
        targetTickLower,
        targetTickUpper,
        rate,
        instantWithdrawSlippageBps
      );
  }

  /// @dev Accept native BNB from WBNB unwrap or StakeManager instantWithdraw.
  receive() external payable override {
    if (!(msg.sender == WRAPPED_NATIVE || msg.sender == address(STAKE_MANAGER))) revert NotWrappedNative();
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  function _isSlisBnbWbnbPool() internal view returns (bool) {
    return (TOKEN0 == SLISBNB && TOKEN1 == WBNB) || (TOKEN0 == WBNB && TOKEN1 == SLISBNB);
  }

  function _poolPriceRate() internal view returns (uint256) {
    return TOKEN0 == SLISBNB ? STAKE_MANAGER.convertSnBnbToBnb(1e18) : STAKE_MANAGER.convertBnbToSnBnb(1e18);
  }
}

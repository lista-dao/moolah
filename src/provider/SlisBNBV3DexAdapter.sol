// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IV3PoolMinimal } from "./interfaces/IV3PoolMinimal.sol";
import { IStakeManager } from "./interfaces/IStakeManager.sol";
import { IV3DexAdapter } from "./interfaces/IV3DexAdapter.sol";
import { ISlisBNBV3DexAdapter } from "./interfaces/ISlisBNBV3DexAdapter.sol";
import { V3PositionLib } from "./libraries/V3PositionLib.sol";
import { SlisBnbInventoryLib } from "./libraries/SlisBnbInventoryLib.sol";

/**
 * @title SlisBNBV3DexAdapter
 * @author Lista DAO
 * @notice slisBNB/BNB specialization of {V3DexAdapter}. Adds:
 *           - exchange-rate-implied fair price (StakeManager rate, not pool spot/TWAP);
 *           - exchange-rate ±1% auto-centered tick range derivation;
 *           - rate-centered `rebalance` with a rate-drift guard + StakeManager inventory conversion.
 */
contract SlisBNBV3DexAdapter is V3DexAdapter, ISlisBNBV3DexAdapter {
  /* ─────────────────────────── constants ──────────────────────────── */

  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  IStakeManager public constant STAKE_MANAGER = IStakeManager(0x1adB950d8bB3dA4bE104211D5AB038628e477fE6);

  uint256 internal constant BPS = 10_000;
  uint256 internal constant INITIAL_RANGE_BPS = 100; // ±1%
  int24 internal constant FALLBACK_HALF_RANGE_TICKS = 500;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Exchange rate at the last successful center/init; used as the range center.
  uint256 public lastCenterRate;

  /// @dev Min relative exchange-rate drift from lastCenterRate before rebalance is allowed (BPS; 0 = off).
  uint256 public centerRateThresholdBps;

  /* ───────────────────────────── events ───────────────────────────── */

  event CenterRateThresholdChanged(uint256 centerRateThresholdBps);
  event LastCenterRateUpdated(uint256 oldCenterRate, uint256 newCenterRate);
  event Rebalanced(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper, uint256 newTokenId);

  /* ───────────────────────────── errors ───────────────────────────── */

  error DeadlineExpired();
  error InsufficientLiquidityMinted();
  error RateDeviationBelowThreshold();
  error InvalidThreshold();
  error NotSlisBnbWbnbPair();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod) {
    // slisBNB/BNB-ONLY: the rate-implied fair price, ±1% tick centering and StakeManager inventory
    // conversion all assume token0 == slisBNB and token1 == WBNB. The base already enforces
    // token0 < token1, and slisBNB < WBNB, so this is the only valid ordering — reject anything else.
    if (!(_token0 == SLISBNB && _token1 == WBNB)) revert NotSlisBnbWbnbPair();
  }

  /**
   * @param _admin   Default admin (upgrade / roles).
   * @param _manager Manager role (sets centerRateThresholdBps).
   */
  function initialize(address _admin, address _manager) external initializer {
    uint256 initialCenterRate;
    if (_isSlisBnbWbnbPool()) initialCenterRate = _poolPriceRate();
    (int24 initialTickLower, int24 initialTickUpper) = _initialTickRange(initialCenterRate);
    __V3DexAdapter_init(_admin, _manager, initialTickLower, initialTickUpper);
    lastCenterRate = initialCenterRate;
    centerRateThresholdBps = INITIAL_RANGE_BPS;
  }

  /* ───────────────────────── view overrides ───────────────────────── */

  /// @dev Fair price = exchange-rate-implied (manipulation-resistant). Falls back to TWAP for any
  ///      non-slisBNB/WBNB pair.
  function fairSqrtPriceX96() public view override(V3DexAdapter, IV3DexAdapter) returns (uint160) {
    if (!_isSlisBnbWbnbPool()) return super.fairSqrtPriceX96();
    return _sqrtPriceX96FromRate(_poolPriceRate());
  }

  /* ─────────────────────── manager / rebalance ────────────────────── */

  /// @notice Set min exchange-rate drift from lastCenterRate required for rebalance (0 = off).
  function setCenterRateThresholdBps(uint256 _centerRateThresholdBps) external onlyRole(MANAGER) {
    if (_centerRateThresholdBps > BPS) revert InvalidThreshold();
    centerRateThresholdBps = _centerRateThresholdBps;
    emit CenterRateThresholdChanged(_centerRateThresholdBps);
  }

  /// @inheritdoc ISlisBNBV3DexAdapter
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint256 deadline
  ) external onlyProvider nonReentrant {
    if (block.timestamp > deadline) revert DeadlineExpired();

    uint256 centerRate;
    bool isSlisPool = _isSlisBnbWbnbPool();
    if (isSlisPool) {
      centerRate = _poolPriceRate();
      _requireCenterRateDeviation(centerRate);
    }

    (int24 newTickLower, int24 newTickUpper) = _initialTickRange(centerRate);
    int24 oldTickLower = tickLower;
    int24 oldTickUpper = tickUpper;

    uint256 total0;
    uint256 total1;
    if (tokenId != 0) {
      (total0, total1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);
    }
    total0 += idleToken0;
    total1 += idleToken1;
    idleToken0 = 0;
    idleToken1 = 0;

    if (tokenId != 0) {
      uint128 liquidity = _getPositionLiquidity();
      if (liquidity > 0) {
        V3PositionLib.decreaseLiquidity(POSITION_MANAGER, tokenId, liquidity, minAmount0, minAmount1);
      }
      (uint256 removed0, uint256 removed1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);
      total0 += removed0;
      total1 += removed1;
      V3PositionLib.burn(POSITION_MANAGER, tokenId);
      tokenId = 0;
    }

    (total0, total1) = _rebalanceInventoryToOptimalRatio(total0, total1, newTickLower, newTickUpper, centerRate);

    tickLower = newTickLower;
    tickUpper = newTickUpper;

    uint128 mintedLiquidity;
    if (total0 > 0 || total1 > 0) {
      (uint256 newTokenId, uint128 liquidity, uint256 used0, uint256 used1) = V3PositionLib.mint(
        POSITION_MANAGER,
        TOKEN0,
        TOKEN1,
        FEE,
        newTickLower,
        newTickUpper,
        total0,
        total1,
        0,
        0
      );
      tokenId = newTokenId;
      mintedLiquidity = liquidity;
      idleToken0 = total0 - used0;
      idleToken1 = total1 - used1;
    } else {
      idleToken0 = total0;
      idleToken1 = total1;
    }

    if (uint256(mintedLiquidity) < minLiquidity) revert InsufficientLiquidityMinted();

    if (isSlisPool) {
      uint256 oldCenterRate = lastCenterRate;
      lastCenterRate = centerRate;
      emit LastCenterRateUpdated(oldCenterRate, centerRate);
    }

    emit Rebalanced(oldTickLower, oldTickUpper, newTickLower, newTickUpper, tokenId);
  }

  /// @dev Accept native BNB from WBNB unwrap or StakeManager instantWithdraw.
  receive() external payable override {
    if (!(msg.sender == WBNB || msg.sender == address(STAKE_MANAGER))) revert NotWBNB();
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  function _initialTickRange(
    uint256 centerRate
  ) internal view returns (int24 initialTickLower, int24 initialTickUpper) {
    int24 tickSpacing = IListaV3Pool(POOL).tickSpacing();

    if (_isSlisBnbWbnbPool()) {
      (initialTickLower, initialTickUpper) = _tickRangeForRate(centerRate, tickSpacing);
    } else {
      (, int24 currentTick) = IV3PoolMinimal(POOL).slot0();
      initialTickLower = _floorTick(currentTick - FALLBACK_HALF_RANGE_TICKS, tickSpacing);
      initialTickUpper = _ceilTick(currentTick + FALLBACK_HALF_RANGE_TICKS, tickSpacing);
    }

    if (initialTickLower >= initialTickUpper) {
      initialTickUpper = initialTickLower + tickSpacing;
    }
  }

  function _tickRangeForRate(
    uint256 centerRate,
    int24 tickSpacing
  ) internal pure returns (int24 initialTickLower, int24 initialTickUpper) {
    uint256 lowerRate = (centerRate * (BPS - INITIAL_RANGE_BPS)) / BPS;
    uint256 upperRate = (centerRate * (BPS + INITIAL_RANGE_BPS)) / BPS;
    initialTickLower = _floorTick(_tickAtSqrtRatio(_sqrtPriceX96FromRate(lowerRate)), tickSpacing);
    initialTickUpper = _ceilTick(_tickAtSqrtRatio(_sqrtPriceX96FromRate(upperRate)), tickSpacing);
  }

  function _rebalanceInventoryToOptimalRatio(
    uint256 total0,
    uint256 total1,
    int24 targetTickLower,
    int24 targetTickUpper,
    uint256 centerRate
  ) internal returns (uint256, uint256) {
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
        _sqrtPriceX96FromRate(centerRate),
        targetTickLower,
        targetTickUpper,
        centerRate
      );
  }

  function _requireCenterRateDeviation(uint256 centerRate) internal view {
    uint256 thresholdBps = centerRateThresholdBps;
    uint256 previousCenterRate = lastCenterRate;
    if (thresholdBps == 0 || previousCenterRate == 0) return;
    uint256 delta = centerRate > previousCenterRate ? centerRate - previousCenterRate : previousCenterRate - centerRate;
    if ((delta * BPS) / previousCenterRate < thresholdBps) revert RateDeviationBelowThreshold();
  }

  function _isSlisBnbWbnbPool() internal view returns (bool) {
    return (TOKEN0 == SLISBNB && TOKEN1 == WBNB) || (TOKEN0 == WBNB && TOKEN1 == SLISBNB);
  }

  function _poolPriceRate() internal view returns (uint256) {
    return TOKEN0 == SLISBNB ? STAKE_MANAGER.convertSnBnbToBnb(1e18) : STAKE_MANAGER.convertBnbToSnBnb(1e18);
  }

  function _sqrtPriceX96FromRate(uint256 rate) internal pure returns (uint160) {
    return uint160(Math.sqrt(FullMath.mulDiv(rate, 1 << 192, 1e18)));
  }

  function _tickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24) {
    int24 low = TickMath.MIN_TICK;
    int24 high = TickMath.MAX_TICK;
    while (low < high) {
      int24 mid = int24((int256(low) + int256(high) + 1) / 2);
      if (TickMath.getSqrtRatioAtTick(mid) <= sqrtPriceX96) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  function _floorTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
    int24 compressed = tick / tickSpacing;
    if (tick < 0 && tick % tickSpacing != 0) compressed--;
    return compressed * tickSpacing;
  }

  function _ceilTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
    int24 compressed = tick / tickSpacing;
    if (tick > 0 && tick % tickSpacing != 0) compressed++;
    return compressed * tickSpacing;
  }
}

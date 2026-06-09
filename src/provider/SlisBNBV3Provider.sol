// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IMoolah, Id } from "moolah/interfaces/IMoolah.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";

import { V3Provider } from "./V3Provider.sol";
import { IStakeManager } from "./interfaces/IStakeManager.sol";
import { V3PositionLib } from "./libraries/V3PositionLib.sol";
import { SlisBnbInventoryLib } from "./libraries/SlisBnbInventoryLib.sol";
import { ISlisBNBxMinter } from "../utils/interfaces/ISlisBNBx.sol";

/**
 * @title SlisBNBV3Provider
 * @author Lista DAO
 * @notice slisBNB/BNB specialization of {V3Provider}. Adds the slisBNB-specific behaviour on top
 *         of the generic V3 LP provider:
 *           - Inventory rebalancing via the slisBNB StakeManager (stake BNB -> slisBNB on excess
 *             BNB; instant-redeem slisBNB -> BNB on excess slisBNB) wired into rebalance().
 *           - slisBNBx reward mirroring: tracks each user's collateral per market and pings the
 *             SlisBNBxMinter after every deposit / withdraw / liquidation; exposes the
 *             ISlisBNBxModule `getUserBalanceInBnb` callback.
 *
 *         Generic position management (deposit / withdraw / redeem / compounding / share oracle)
 *         lives in {V3Provider}.
 */
contract SlisBNBV3Provider is V3Provider {
  /* ─────────────────────────── constants ──────────────────────────── */

  /// @dev slisBNB liquid-staking token (BSC). The non-WBNB leg of the managed pool.
  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

  /// @dev Lista slisBNB StakeManager. Used to rebalance inventory between the two pool legs:
  ///      stake BNB -> slisBNB (deposit) and instant-redeem slisBNB -> BNB (instantWithdraw).
  IStakeManager public constant STAKE_MANAGER = IStakeManager(0x1adB950d8bB3dA4bE104211D5AB038628e477fE6);

  /// @dev Virtual address used by the resilient oracle to price native BNB.
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  uint256 internal constant BPS = 10_000;
  uint256 internal constant INITIAL_RANGE_BPS = 100;
  int24 internal constant FALLBACK_HALF_RANGE_TICKS = 500;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev user account > market id > amount of collateral(shares) deposited
  mapping(address => mapping(Id => uint256)) public userMarketDeposit;

  /// @dev user account > total amount of collateral(shares) deposited
  mapping(address => uint256) public userTotalDeposit;

  /// @dev slisBNBxMinter address
  address public slisBNBxMinter;

  /// @dev Exchange rate used to derive the current centered slisBNB/BNB tick range.
  uint256 public lastCenterRate;

  /// @dev Min relative exchange-rate drift from lastCenterRate before rebalance is allowed.
  ///      BPS precision; 0 disables the rate-drift guard.
  uint256 public centerRateThresholdBps;

  /* ───────────────────────────── events ───────────────────────────── */

  event SlisBNBxMinterChanged(address indexed minter);
  event CenterRateThresholdChanged(uint256 centerRateThresholdBps);
  event LastCenterRateUpdated(uint256 oldCenterRate, uint256 newCenterRate);

  /* ───────────────────────────── errors ───────────────────────────── */

  error LengthMismatch();
  error DeadlineExpired();
  error InsufficientLiquidityMinted();
  error RateDeviationBelowThreshold();
  error InvalidThreshold();

  /* ─────────────────────── constructor / init ─────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _moolah,
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3Provider(_moolah, _positionManager, _token0, _token1, _fee, _twapPeriod) {}

  /**
   * @param _admin            Default admin (can upgrade, grant roles)
   * @param _manager          Manager role (can rebalance position range)
   * @param _bot              Bot address granted BOT role (can trigger rebalance)
   * @param _resilientOracle  Resilient oracle for pricing TOKEN0 and TOKEN1
   * @param _name             ERC20 name for shares token
   * @param _symbol           ERC20 symbol for shares token
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _resilientOracle,
    string calldata _name,
    string calldata _symbol
  ) external initializer {
    uint256 initialCenterRate;
    if (_isSlisBnbWbnbPool()) initialCenterRate = _poolPriceRate();
    (int24 initialTickLower, int24 initialTickUpper) = _initialTickRange(initialCenterRate);
    __V3Provider_init(_admin, _manager, _bot, _resilientOracle, initialTickLower, initialTickUpper, _name, _symbol);
    lastCenterRate = initialCenterRate;
    centerRateThresholdBps = INITIAL_RANGE_BPS;
  }

  /* ─────────────────── slisBNBx: sync / view ──────────────────────── */

  /**
   * @notice Returns the user's total deposited collateral value expressed in BNB (18 decimals).
   *         Called by SlisBNBxMinter as the ISlisBNBxModule callback to compute how much
   *         slisBNBx the user is entitled to.
   * @param account The user whose position is being priced.
   */
  function getUserBalanceInBnb(address account) external view returns (uint256) {
    uint256 shares = userTotalDeposit[account];
    if (shares == 0) return 0;

    uint256 supply = totalSupply();
    if (supply == 0) return 0;

    // Value at the exchange-rate-implied price (manipulation-resistant), consistent with peek().
    (uint256 total0, uint256 total1) = _getTotalAmountsAt(_valuationSqrtPriceX96());

    uint256 user0 = (total0 * shares) / supply;
    uint256 user1 = (total1 * shares) / supply;

    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8-decimal USD
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8-decimal USD
    uint256 bnbPrice = IOracle(resilientOracle).peek(BNB_ADDRESS); // 8-decimal USD

    // Scale up by 1e18 before dividing by bnbPrice so the result is 18-decimal BNB.
    uint256 value0 = (user0 * price0 * 1e18) / (10 ** DECIMALS0);
    uint256 value1 = (user1 * price1 * 1e18) / (10 ** DECIMALS1);

    return (value0 + value1) / bnbPrice;
  }

  /**
   * @notice Manually sync one user's deposit tracking and slisBNBx balance for a market.
   * @param id      Moolah market Id (collateralToken must equal address(this)).
   * @param account User to sync.
   */
  function syncUserBalance(Id id, address account) external {
    if (MOOLAH.idToMarketParams(id).collateralToken != address(this)) revert InvalidMarket();
    _syncPosition(id, account);
  }

  /**
   * @notice Batch sync multiple users across multiple markets.
   * @param ids      Array of market Ids.
   * @param accounts Array of user addresses (parallel to ids).
   */
  function bulkSyncUserBalance(Id[] calldata ids, address[] calldata accounts) external {
    if (ids.length != accounts.length) revert LengthMismatch();
    for (uint256 i = 0; i < accounts.length; i++) {
      if (MOOLAH.idToMarketParams(ids[i]).collateralToken != address(this)) revert InvalidMarket();
      _syncPosition(ids[i], accounts[i]);
    }
  }

  /* ──────────────────── manager: slisBNBxMinter ───────────────────── */

  /// @notice Set (or unset) the SlisBNBxMinter plugin. Pass address(0) to disable.
  ///         When set, deposit/withdraw/liquidate call minter.rebalance(account).
  function setSlisBNBxMinter(address _slisBNBxMinter) external onlyRole(MANAGER) {
    slisBNBxMinter = _slisBNBxMinter;
    emit SlisBNBxMinterChanged(_slisBNBxMinter);
  }

  /// @notice Set min exchange-rate drift from lastCenterRate required for rebalance.
  ///         Pass 0 to disable the guard.
  function setCenterRateThresholdBps(uint256 _centerRateThresholdBps) external onlyRole(MANAGER) {
    if (_centerRateThresholdBps > BPS) revert InvalidThreshold();
    centerRateThresholdBps = _centerRateThresholdBps;
    emit CenterRateThresholdChanged(_centerRateThresholdBps);
  }

  /**
   * @notice Recenter the managed position to the exchange-rate-derived range.
   * @dev Caller supplies execution guards only. The target ticks and reinvested amounts are computed on-chain.
   * @param minAmount0  Min TOKEN0 to receive when removing old liquidity.
   * @param minAmount1  Min TOKEN1 to receive when removing old liquidity.
   * @param minLiquidity Minimum liquidity that must be minted in the new position.
   * @param deadline    Latest acceptable timestamp for this rebalance transaction.
   */
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint256 deadline
  ) external onlyRole(BOT) nonReentrant {
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

    (uint256 total0, uint256 total1) = _collectAll();

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

  /* ────────────────────────── hook overrides ──────────────────────── */

  /// @dev Mirror the collateral change into deposit tracking + slisBNBx after every
  ///      deposit / withdraw / liquidation.
  function _afterCollateralChange(Id id, address account) internal override {
    _syncPosition(id, account);
  }

  /// @dev Accepts native BNB from WBNB unwrap or from the StakeManager on instantWithdraw.
  receive() external payable override {
    if (!(msg.sender == WBNB || msg.sender == address(STAKE_MANAGER))) revert NotWBNB();
  }

  /// @dev Lending-oracle valuation price = the slisBNB exchange rate (BNB per slisBNB), NOT the pool
  ///      spot/TWAP. The position is split into (slisBNB, WBNB) at this fair price, so a pool trade
  ///      that pushes the AMM price within the narrow band cannot move the reported collateral value
  ///      (PRD §4.5). The rate comes from the slisBNB StakeManager (on-chain staking state).
  ///      For any non-slisBNB/WBNB pair this falls back to the base TWAP pricing.
  function _valuationSqrtPriceX96() internal view override returns (uint160) {
    bool slisIs0 = TOKEN0 == SLISBNB && TOKEN1 == WBNB;
    bool wbnbIs0 = TOKEN0 == WBNB && TOKEN1 == SLISBNB;
    if (!slisIs0 && !wbnbIs0) return super._valuationSqrtPriceX96();

    return _sqrtPriceX96FromRate(_poolPriceRate());
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  /// @dev Initial slisBNB/WBNB range is exchange-rate ±1%, snapped to pool tick spacing.
  ///      For non-slis test pools, fall back to a spot-centered range so generic V3 tests remain usable.
  function _initialTickRange(uint256 centerRate) internal view returns (int24 initialTickLower, int24 initialTickUpper) {
    int24 tickSpacing = IListaV3Pool(POOL).tickSpacing();

    if (_isSlisBnbWbnbPool()) {
      (initialTickLower, initialTickUpper) = _tickRangeForRate(centerRate, tickSpacing);
    } else {
      (, int24 currentTick, , , , , ) = IListaV3Pool(POOL).slot0();
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

  function _isSlisBnbWbnbPool() internal view returns (bool) {
    return (TOKEN0 == SLISBNB && TOKEN1 == WBNB) || (TOKEN0 == WBNB && TOKEN1 == SLISBNB);
  }

  function _poolPriceRate() internal view returns (uint256) {
    return TOKEN0 == SLISBNB ? STAKE_MANAGER.convertSnBnbToBnb(1e18) : STAKE_MANAGER.convertBnbToSnBnb(1e18);
  }

  function _sqrtPriceX96FromRate(uint256 rate) internal pure returns (uint160) {
    return uint160(Math.sqrt(FullMath.mulDiv(rate, 1 << 192, 1e18)));
  }

  function _tickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
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

  /// @dev Reads the user's current Moolah collateral for `id`, diffs against the last
  ///      recorded snapshot in `userMarketDeposit`, updates `userTotalDeposit`, then
  ///      calls `slisBNBxMinter.rebalance(account)` if a minter is configured.
  function _syncPosition(Id id, address account) internal {
    uint256 current = MOOLAH.position(id, account).collateral;

    if (current >= userMarketDeposit[account][id]) {
      userTotalDeposit[account] += current - userMarketDeposit[account][id];
    } else {
      userTotalDeposit[account] -= userMarketDeposit[account][id] - current;
    }
    userMarketDeposit[account][id] = current;

    if (slisBNBxMinter != address(0)) {
      ISlisBNBxMinter(slisBNBxMinter).rebalance(account);
    }
  }
}

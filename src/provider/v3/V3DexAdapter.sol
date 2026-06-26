// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { LiquidityAmounts } from "lista-dao-contracts/libraries/LiquidityAmounts.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";

import { INonfungiblePositionManager } from "../interfaces/INonfungiblePositionManager.sol";
import { V3PositionLib } from "../libraries/V3PositionLib.sol";
import { SwapInventoryLib } from "../libraries/SwapInventoryLib.sol";
import { IListaV3Factory } from "lista-v3/core/interfaces/IListaV3Factory.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IWBNB } from "../interfaces/IWBNB.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";
import { IV3Provider } from "../interfaces/IV3Provider.sol";
import { IV3PoolMinimal } from "../interfaces/IV3PoolMinimal.sol";

/**
 * @title V3DexAdapter
 * @author Lista DAO
 * @notice Generic, abstract DEX-custodian for a single Uniswap V3 / PancakeSwap V3 concentrated
 *         liquidity NFT. Sole holder of the position (tokenId), the idle inventory and all NPM/pool
 *         interaction. The vault (V3Provider) drives it through `onlyProvider` writes; the vault and
 *         the oracle (SlisBNBV3ProviderOracle) read its raw-NAV/composition views via staticcall.
 *
 *         Splitting NFT custody + DEX math out of the vault keeps each runtime under EIP-170 and
 *         isolates the position state from the share-accounting / pricing logic.
 *
 *         The rebalance (rate-centered recenter) and the DEX-agnostic, backend-built inventory-conversion
 *         swap (+ swap-pair whitelist) live here and are shared by every rate-implied pair.
 *
 * Extension points (rate-implied subclasses override):
 *   - _lstNativeRate(): the LST↔native exchange rate — the range center and the fair-price anchor.
 *   - fairSqrtPriceX96(): the valuation price (rate-implied by default; wstETH/wbETH clamp the pool TWAP
 *     to the rate). receive() may also be overridden to widen accepted native senders.
 */
abstract contract V3DexAdapter is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  IV3DexAdapter
{
  using SafeERC20 for IERC20;

  /* ─────────────────────────── immutables ─────────────────────────── */

  INonfungiblePositionManager public immutable POSITION_MANAGER;
  address public immutable POOL;
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  uint24 public immutable FEE;
  uint32 public immutable TWAP_PERIOD;
  uint8 public immutable DECIMALS0;
  uint8 public immutable DECIMALS1;

  /// @dev Wrapped-native token of the chain (WBNB on BSC, WETH on Ethereum). Native sent on deposit
  ///      is wrapped to this before forwarding; refunds/withdrawals unwrap it back to native.
  address public immutable WRAPPED_NATIVE;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  uint256 internal constant BPS = 10_000;
  /// @dev Half-width of the rate-centered range for rate-implied pairs (±1%).
  uint256 internal constant INITIAL_RANGE_BPS = 100;
  /// @dev Fallback half-range (ticks) around spot for non-rate (TWAP) pairs.
  int24 internal constant FALLBACK_HALF_RANGE_TICKS = 500;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev The vault (V3Provider) authorized to drive this adapter. Set once via setProvider.
  address public provider;

  /// @dev tokenId of the V3 NFT held by this adapter; 0 means no position yet.
  uint256 public tokenId;

  int24 public tickLower;
  int24 public tickUpper;

  /// @dev Idle inventory from ratio mismatch during compound/rebalance. Tracked in storage (not
  ///      balanceOf) so donations cannot inflate the reported NAV.
  uint256 public idleToken0;
  uint256 public idleToken1;

  /// @dev Exchange rate at the last successful center/init; used as the range center. Rate-implied
  ///      pairs only (0 for pure-TWAP pairs).
  uint256 public lastCenterRate;

  /// @dev Min relative exchange-rate drift from lastCenterRate before rebalance is allowed (BPS; 0 = off).
  uint256 public centerRateThresholdBps;

  /// @dev Whitelisted swap venues the rebalance inventory conversion may call. The BOT backend builds the
  ///      swap calldata; the adapter only allows whitelisted targets (à la {Liquidator}'s pairWhitelist).
  ///      Chain/venue-agnostic: a DEX pool, an aggregator, or any router that converts TOKEN0<->TOKEN1.
  mapping(address => bool) public swapPairWhitelist;

  /// @dev Reserved storage for future base variables (keep subclass storage stable on upgrade).
  uint256[47] private __gap;

  /* ───────────────────────────── events ───────────────────────────── */

  event ProviderSet(address indexed provider);
  event Compounded(uint256 amount0, uint256 amount1, uint128 liquidityAdded);
  event LiquidityAdded(uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used);
  event LiquidityRemoved(uint256 shares, uint256 totalShares, uint256 amount0, uint256 amount1, address receiver);
  event CenterRateThresholdChanged(uint256 centerRateThresholdBps);
  event LastCenterRateUpdated(uint256 oldCenterRate, uint256 newCenterRate);
  event Rebalanced(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper, uint256 newTokenId);
  event SwapPairWhitelistSet(address indexed swapPair, bool status);

  /* ───────────────────────────── errors ───────────────────────────── */

  error ZeroAddress();
  error TokenOrderInvalid();
  error ZeroFee();
  error ZeroTwapPeriod();
  error PoolDoesNotExist();
  error InvalidTickRange();
  error OnlyProvider();
  error ProviderAlreadySet();
  error ProviderAdapterMismatch();
  error BnbTransferFailed();
  error NotWrappedNative();
  error DeadlineExpired();
  error InsufficientLiquidityMinted();
  error RateDeviationBelowThreshold();
  error InvalidThreshold();
  error NotWhitelistedPair();
  error InvalidSwapPair();

  /* ─────────────────────────── constructor ────────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod,
    address _wrappedNative
  ) {
    if (_positionManager == address(0)) revert ZeroAddress();
    if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
    if (_wrappedNative == address(0)) revert ZeroAddress();
    if (_token0 >= _token1) revert TokenOrderInvalid();
    if (_fee == 0) revert ZeroFee();
    if (_twapPeriod == 0) revert ZeroTwapPeriod();

    address _pool = IListaV3Factory(INonfungiblePositionManager(_positionManager).factory()).getPool(
      _token0,
      _token1,
      _fee
    );
    if (_pool == address(0)) revert PoolDoesNotExist();

    POSITION_MANAGER = INonfungiblePositionManager(_positionManager);
    TOKEN0 = _token0;
    TOKEN1 = _token1;
    FEE = _fee;
    POOL = _pool;
    TWAP_PERIOD = _twapPeriod;
    WRAPPED_NATIVE = _wrappedNative;
    DECIMALS0 = IERC20Metadata(_token0).decimals();
    DECIMALS1 = IERC20Metadata(_token1).decimals();

    _disableInitializers();
  }

  /* ─────────────────────────── initializer ────────────────────────── */

  function __V3DexAdapter_init(
    address _admin,
    address _manager,
    int24 _tickLower,
    int24 _tickUpper
  ) internal onlyInitializing {
    if (_admin == address(0) || _manager == address(0)) revert ZeroAddress();
    if (_tickLower >= _tickUpper) revert InvalidTickRange();

    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);

    tickLower = _tickLower;
    tickUpper = _tickUpper;
  }

  /// @notice Wire the vault that may drive this adapter. One-time, admin-only.
  /// @dev Cross-validates the wiring: the vault's immutable ADAPTER (set in its constructor) must point
  ///      back to THIS adapter. Guards against a silent mis-wire — especially across same-pair adapters —
  ///      that would permanently brick the adapter (setProvider is one-time) or misprice collateral.
  function setProvider(address _provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_provider == address(0)) revert ZeroAddress();
    if (provider != address(0)) revert ProviderAlreadySet();
    if (IV3Provider(_provider).ADAPTER() != address(this)) revert ProviderAdapterMismatch();
    provider = _provider;
    emit ProviderSet(_provider);
  }

  modifier onlyProvider() {
    if (msg.sender != provider) revert OnlyProvider();
    _;
  }

  /* ─────────────────────── writes (onlyProvider) ──────────────────── */

  /// @inheritdoc IV3DexAdapter
  function addLiquidity(
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address refundTo
  ) external onlyProvider nonReentrant returns (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used) {
    if (tokenId == 0) {
      (tokenId, liquidityAdded, amount0Used, amount1Used) = V3PositionLib.mint(
        POSITION_MANAGER,
        TOKEN0,
        TOKEN1,
        FEE,
        tickLower,
        tickUpper,
        amount0Desired,
        amount1Desired,
        amount0Min,
        amount1Min
      );
    } else {
      (liquidityAdded, amount0Used, amount1Used) = V3PositionLib.increaseLiquidity(
        POSITION_MANAGER,
        TOKEN0,
        TOKEN1,
        tokenId,
        amount0Desired,
        amount1Desired,
        amount0Min,
        amount1Min
      );
    }

    // Refund unused input (ratio mismatch) to the depositor. The wrapped-native token is unwrapped to native coin.
    uint256 refund0 = amount0Desired - amount0Used;
    uint256 refund1 = amount1Desired - amount1Used;
    if (refund0 > 0) _sendToken(TOKEN0, refund0, payable(refundTo));
    if (refund1 > 0) _sendToken(TOKEN1, refund1, payable(refundTo));

    emit LiquidityAdded(liquidityAdded, amount0Used, amount1Used);
  }

  /// @inheritdoc IV3DexAdapter
  function removeLiquidity(
    uint256 shares,
    uint256 totalShares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external onlyProvider nonReentrant returns (uint256 amount0, uint256 amount1) {
    uint128 totalLiq = _getPositionLiquidity();
    uint128 liquidityToRemove = totalShares == 0 ? 0 : uint128((uint256(totalLiq) * shares) / totalShares);

    if (liquidityToRemove > 0) {
      V3PositionLib.decreaseLiquidity(POSITION_MANAGER, tokenId, liquidityToRemove, minAmount0, minAmount1);
      (amount0, amount1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);
    }

    // Pro-rata idle inventory (finding C): redeem the same fraction of idle as of liquidity.
    if (totalShares > 0) {
      uint256 idleOut0 = (idleToken0 * shares) / totalShares;
      uint256 idleOut1 = (idleToken1 * shares) / totalShares;
      if (idleOut0 > 0) {
        idleToken0 -= idleOut0;
        amount0 += idleOut0;
      }
      if (idleOut1 > 0) {
        idleToken1 -= idleOut1;
        amount1 += idleOut1;
      }
    }

    if (amount0 > 0) _sendToken(TOKEN0, amount0, payable(receiver));
    if (amount1 > 0) _sendToken(TOKEN1, amount1, payable(receiver));

    emit LiquidityRemoved(shares, totalShares, amount0, amount1, receiver);
  }

  /// @inheritdoc IV3DexAdapter
  function collectAndCompound() external onlyProvider nonReentrant {
    _collectAndCompound();
  }

  /* ─────────────────────── manager / rebalance ────────────────────── */

  /// @inheritdoc IV3DexAdapter
  function setCenterRateThresholdBps(uint256 _centerRateThresholdBps) external onlyRole(MANAGER) {
    if (_centerRateThresholdBps > BPS) revert InvalidThreshold();
    centerRateThresholdBps = _centerRateThresholdBps;
    emit CenterRateThresholdChanged(_centerRateThresholdBps);
  }

  /// @notice Whitelist (or remove) a swap venue the rebalance inventory conversion may call. Backend-built
  ///         calldata can only target whitelisted venues.
  /// @dev Defense-in-depth: a swap venue must never be a token / pool / NPM the adapter holds or trusts,
  ///      else crafted swapData could move the adapter's own inventory (e.g. TOKEN0.transfer) or position.
  function setSwapPairWhitelist(address swapPair, bool status) external onlyRole(MANAGER) {
    if (swapPair == address(0)) revert ZeroAddress();
    if (
      status && (swapPair == TOKEN0 || swapPair == TOKEN1 || swapPair == POOL || swapPair == address(POSITION_MANAGER))
    ) revert InvalidSwapPair();
    swapPairWhitelist[swapPair] = status;
    emit SwapPairWhitelistSet(swapPair, status);
  }

  /// @inheritdoc IV3DexAdapter
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint256 deadline,
    bytes calldata swapData
  ) external onlyProvider nonReentrant {
    if (block.timestamp > deadline) revert DeadlineExpired();

    // Rate-implied pairs recenter around the LST↔native rate; pure-TWAP pairs (rate == 0) recenter
    // around the spot tick and skip the rate-drift guard / inventory conversion.
    uint256 centerRate = _lstNativeRate();
    bool rateImplied = centerRate != 0;
    if (rateImplied) _requireCenterRateDeviation(centerRate);

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

    (total0, total1) = _convertToOptimalRatio(total0, total1, newTickLower, newTickUpper, centerRate, swapData);

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

    if (rateImplied) {
      uint256 oldCenterRate = lastCenterRate;
      lastCenterRate = centerRate;
      emit LastCenterRateUpdated(oldCenterRate, centerRate);
    }

    emit Rebalanced(oldTickLower, oldTickUpper, newTickLower, newTickUpper, tokenId);
  }

  /* ───────────────────────── views (staticcall) ───────────────────── */

  /// @inheritdoc IV3DexAdapter
  function positionAmountsAt(uint160 sqrtPriceX96) public view returns (uint256 total0, uint256 total1) {
    if (tokenId == 0) return (idleToken0, idleToken1);

    (, , , , , , , uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) = POSITION_MANAGER.positions(
      tokenId
    );

    (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
      sqrtPriceX96,
      TickMath.getSqrtRatioAtTick(tickLower),
      TickMath.getSqrtRatioAtTick(tickUpper),
      liquidity
    );

    total0 = amount0 + uint256(tokensOwed0) + idleToken0;
    total1 = amount1 + uint256(tokensOwed1) + idleToken1;
  }

  /// @inheritdoc IV3DexAdapter
  function amountsForLiquidity(
    uint128 liquidity,
    uint160 sqrtPriceX96
  ) external view returns (uint256 amount0, uint256 amount1) {
    return
      LiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceX96,
        TickMath.getSqrtRatioAtTick(tickLower),
        TickMath.getSqrtRatioAtTick(tickUpper),
        liquidity
      );
  }

  /// @inheritdoc IV3DexAdapter
  function totalLiquidity() external view returns (uint128) {
    return _getPositionLiquidity();
  }

  /// @inheritdoc IV3DexAdapter
  /// @dev Rate-implied (manipulation-resistant) when the subclass supplies a non-zero LST↔native
  ///      rate via _lstNativeRate(); otherwise falls back to the pool TWAP.
  function fairSqrtPriceX96() public view virtual returns (uint160) {
    uint256 rate = _lstNativeRate();
    if (rate == 0) return TickMath.getSqrtRatioAtTick(_twapTick());
    return _sqrtPriceX96FromRate(rate);
  }

  /// @inheritdoc IV3DexAdapter
  function spotSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
    // Decode only sqrtPriceX96/tick (width-agnostic to feeProtocol uint8/uint32; see IV3PoolMinimal).
    (sqrtPriceX96, ) = IV3PoolMinimal(POOL).slot0();
  }

  /// @inheritdoc IV3DexAdapter
  function previewAddLiquidity(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    uint160 sqrtPriceX96 = spotSqrtPriceX96();
    uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
    liquidity = LiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      sqrtLower,
      sqrtUpper,
      amount0Desired,
      amount1Desired
    );
    (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
  }

  /// @inheritdoc IV3DexAdapter
  function previewRemoveLiquidity(
    uint256 shares,
    uint256 totalShares
  ) external view returns (uint256 amount0, uint256 amount1) {
    if (totalShares == 0 || shares == 0) return (0, 0);
    uint128 liquidityToRemove = uint128((uint256(_getPositionLiquidity()) * shares) / totalShares);
    (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
      spotSqrtPriceX96(),
      TickMath.getSqrtRatioAtTick(tickLower),
      TickMath.getSqrtRatioAtTick(tickUpper),
      liquidityToRemove
    );
    amount0 += (idleToken0 * shares) / totalShares;
    amount1 += (idleToken1 * shares) / totalShares;
  }

  /// @notice TWAP tick over TWAP_PERIOD seconds.
  function getTwapTick() external view returns (int24) {
    return _twapTick();
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  function _collectAndCompound() internal {
    if (tokenId == 0) return;

    (uint256 fees0, uint256 fees1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);

    uint256 toCompound0 = fees0 + idleToken0;
    uint256 toCompound1 = fees1 + idleToken1;
    if (toCompound0 == 0 && toCompound1 == 0) return;

    (uint128 liquidityAdded, uint256 used0, uint256 used1) = V3PositionLib.increaseLiquidity(
      POSITION_MANAGER,
      TOKEN0,
      TOKEN1,
      tokenId,
      toCompound0,
      toCompound1,
      0,
      0
    );

    idleToken0 = toCompound0 - used0;
    idleToken1 = toCompound1 - used1;

    emit Compounded(toCompound0, toCompound1, liquidityAdded);
  }

  function _getPositionLiquidity() internal view returns (uint128 liquidity) {
    if (tokenId == 0) return 0;
    (, , , , , , , liquidity, , , , ) = POSITION_MANAGER.positions(tokenId);
  }

  function _twapTick() internal view returns (int24 twapTick) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = TWAP_PERIOD;
    secondsAgos[1] = 0;
    (int56[] memory tickCumulatives, ) = IListaV3Pool(POOL).observe(secondsAgos);
    int56 delta = tickCumulatives[1] - tickCumulatives[0];
    twapTick = int24(delta / int56(uint56(TWAP_PERIOD)));
    if (delta < 0 && (delta % int56(uint56(TWAP_PERIOD)) != 0)) twapTick--;
  }

  /// @dev Send `token` to `to`, unwrapping the wrapped-native token to native coin.
  function _sendToken(address token, uint256 amount, address payable to) internal {
    if (token == WRAPPED_NATIVE) {
      IWBNB(WRAPPED_NATIVE).withdraw(amount);
      (bool ok, ) = to.call{ value: amount }("");
      if (!ok) revert BnbTransferFailed();
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }

  /// @dev Accepts native coin from the wrapped-native unwrap, or from a whitelisted swap venue that
  ///      settles the wrapped-native leg as the native coin (e.g. a StakeManager instant-redeem). The
  ///      rebalance swap wraps that native back into the wrapped-native token (see {SwapInventoryLib}).
  receive() external payable virtual {
    if (msg.sender != WRAPPED_NATIVE && !swapPairWhitelist[msg.sender]) revert NotWrappedNative();
  }

  /* ─────────────────── rate-centering math (shared) ────────────────── */

  /// @dev Tick range for the position. Rate-implied (centerRate != 0): ±INITIAL_RANGE_BPS around the
  ///      rate-derived price. Pure-TWAP (centerRate == 0): ±FALLBACK_HALF_RANGE_TICKS around spot.
  function _initialTickRange(
    uint256 centerRate
  ) internal view returns (int24 initialTickLower, int24 initialTickUpper) {
    int24 tickSpacing = IListaV3Pool(POOL).tickSpacing();

    if (centerRate != 0) {
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
  ) internal view returns (int24 initialTickLower, int24 initialTickUpper) {
    uint256 lowerRate = (centerRate * (BPS - INITIAL_RANGE_BPS)) / BPS;
    uint256 upperRate = (centerRate * (BPS + INITIAL_RANGE_BPS)) / BPS;
    initialTickLower = _floorTick(_tickAtSqrtRatio(_sqrtPriceX96FromRate(lowerRate)), tickSpacing);
    initialTickUpper = _ceilTick(_tickAtSqrtRatio(_sqrtPriceX96FromRate(upperRate)), tickSpacing);
  }

  function _requireCenterRateDeviation(uint256 centerRate) internal view {
    uint256 thresholdBps = centerRateThresholdBps;
    uint256 previousCenterRate = lastCenterRate;
    if (thresholdBps == 0 || previousCenterRate == 0) return;
    uint256 delta = centerRate > previousCenterRate ? centerRate - previousCenterRate : previousCenterRate - centerRate;
    if ((delta * BPS) / previousCenterRate < thresholdBps) revert RateDeviationBelowThreshold();
  }

  /// @dev Convert an exchange `rate` — token1-per-token0 scaled by 1e18 (1e18 ⇒ 1 WHOLE token0 is worth
  ///      1 WHOLE token1; subclasses return it in these human/whole-token terms) — into the pool
  ///      sqrtPriceX96, which encodes the RAW (smallest-unit) price token1/token0. The two tokens may have
  ///      different decimals (the wrapped-native is 18; the paired token need not be), so adjust by the
  ///      decimal difference:  token1_raw/token0_raw = (rate / 1e18) · 10^(DECIMALS1 − DECIMALS0).
  function _sqrtPriceX96FromRate(uint256 rate) internal view returns (uint160) {
    uint256 priceX192; // (token1_raw / token0_raw) · 2^192
    if (DECIMALS1 >= DECIMALS0) {
      priceX192 = FullMath.mulDiv(rate * (uint256(10) ** (DECIMALS1 - DECIMALS0)), 1 << 192, 1e18);
    } else {
      priceX192 = FullMath.mulDiv(rate, 1 << 192, 1e18 * (uint256(10) ** (DECIMALS0 - DECIMALS1)));
    }
    return uint160(Math.sqrt(priceX192));
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

  /* ────────────────────────── extension hooks ─────────────────────── */

  /// @dev LST↔native exchange rate (native per LST, 1e18). 0 ⇒ no rate (pure-TWAP pair): the base
  ///      uses pool TWAP for the fair price and a spot-centered range. Rate-implied subclasses
  ///      (slisBNB via StakeManager, wstETH via stEthPerToken) override this.
  function _lstNativeRate() internal view virtual returns (uint256) {
    return 0;
  }

  /// @dev DEX-agnostic, backend-built rebalance inventory conversion, shared by all rate-implied pairs
  ///      (slisBNB/WBNB, wstETH/WETH, wbETH/WETH). `swapData` (when non-empty) ABI-encodes
  ///      (address swapPair, bool sellToken0, uint256 amountIn, uint256 amountOutMin, bool nativeIn,
  ///      bytes innerSwapData): the adapter requires `swapPair` whitelisted and forwards `innerSwapData`
  ///      via a low-level call, bounding the swap by the backend's `amountOutMin` (see {SwapInventoryLib}).
  ///      `nativeIn` ⇒ a native-input venue (the wrapped-native leg is unwrapped + sent as msg.value, e.g.
  ///      StakeManager.deposit). Empty swapData ⇒ recenter without converting (also the TWAP-pair default).
  function _convertToOptimalRatio(
    uint256 total0,
    uint256 total1,
    int24 /* targetTickLower */,
    int24 /* targetTickUpper */,
    uint256 /* rate */,
    bytes calldata swapData
  ) internal virtual returns (uint256, uint256) {
    if (swapData.length == 0) return (total0, total1);
    (address swapPair, bool sellToken0, uint256 amountIn, uint256 amountOutMin, bool nativeIn, bytes memory inner) = abi
      .decode(swapData, (address, bool, uint256, uint256, bool, bytes));
    if (!swapPairWhitelist[swapPair]) revert NotWhitelistedPair();
    return
      SwapInventoryLib.swap(
        swapPair,
        TOKEN0,
        TOKEN1,
        sellToken0,
        amountIn,
        amountOutMin,
        inner,
        total0,
        total1,
        WRAPPED_NATIVE,
        nativeIn
      );
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

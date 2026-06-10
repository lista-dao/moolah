// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { LiquidityAmounts } from "lista-dao-contracts/libraries/LiquidityAmounts.sol";

import { INonfungiblePositionManager } from "./interfaces/INonfungiblePositionManager.sol";
import { V3PositionLib } from "./libraries/V3PositionLib.sol";
import { IListaV3Factory } from "lista-v3/core/interfaces/IListaV3Factory.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IWBNB } from "./interfaces/IWBNB.sol";
import { IV3DexAdapter } from "./interfaces/IV3DexAdapter.sol";
import { IV3PoolMinimal } from "./interfaces/IV3PoolMinimal.sol";

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
 * Extension points (slisBNB/BNB subclass overrides):
 *   - fairSqrtPriceX96(): exchange-rate-implied price instead of pool TWAP.
 *   - receive(): widen accepted native-BNB senders (StakeManager instantWithdraw).
 *   - rebalance(): added by the subclass (rate-centered recenter + inventory conversion).
 */
abstract contract V3DexAdapter is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IV3DexAdapter {
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

  /// @dev BSC wrapped native token.
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  bytes32 public constant MANAGER = keccak256("MANAGER");

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

  /// @dev Reserved storage for future base variables (keep subclass storage stable on upgrade).
  uint256[50] private __gap;

  /* ───────────────────────────── events ───────────────────────────── */

  event ProviderSet(address indexed provider);
  event Compounded(uint256 amount0, uint256 amount1, uint128 liquidityAdded);
  event LiquidityAdded(uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used);
  event LiquidityRemoved(uint256 shares, uint256 totalShares, uint256 amount0, uint256 amount1, address receiver);

  /* ───────────────────────────── errors ───────────────────────────── */

  error ZeroAddress();
  error TokenOrderInvalid();
  error ZeroFee();
  error ZeroTwapPeriod();
  error PoolDoesNotExist();
  error InvalidTickRange();
  error OnlyProvider();
  error ProviderAlreadySet();
  error BnbTransferFailed();
  error NotWBNB();

  /* ─────────────────────────── constructor ────────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _positionManager, address _token0, address _token1, uint24 _fee, uint32 _twapPeriod) {
    if (_positionManager == address(0)) revert ZeroAddress();
    if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
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
  function setProvider(address _provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_provider == address(0)) revert ZeroAddress();
    if (provider != address(0)) revert ProviderAlreadySet();
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

    // Refund unused input (ratio mismatch) to the depositor. WBNB is unwrapped to native BNB.
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
  function fairSqrtPriceX96() public view virtual returns (uint160) {
    return TickMath.getSqrtRatioAtTick(_twapTick());
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

  /// @dev Send `token` to `to`, unwrapping WBNB to native BNB.
  function _sendToken(address token, uint256 amount, address payable to) internal {
    if (token == WBNB) {
      IWBNB(WBNB).withdraw(amount);
      (bool ok, ) = to.call{ value: amount }("");
      if (!ok) revert BnbTransferFailed();
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }

  /// @dev Accepts native BNB from WBNB unwrap. Subclasses widen the allowed senders.
  receive() external payable virtual {
    if (msg.sender != WBNB) revert NotWBNB();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

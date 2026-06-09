// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TickMath } from "lista-dao-contracts/libraries/TickMath.sol";
import { LiquidityAmounts } from "lista-dao-contracts/libraries/LiquidityAmounts.sol";

import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";

import { INonfungiblePositionManager } from "./interfaces/INonfungiblePositionManager.sol";
import { V3PositionLib } from "./libraries/V3PositionLib.sol";
import { IListaV3Factory } from "lista-v3/core/interfaces/IListaV3Factory.sol";
import { IListaV3Pool } from "lista-v3/core/interfaces/IListaV3Pool.sol";
import { IWBNB } from "./interfaces/IWBNB.sol";
import { IV3Provider } from "./interfaces/IV3Provider.sol";

/**
 * @title V3Provider
 * @author Lista DAO
 * @notice Generic, abstract base that manages a single Uniswap V3 / PancakeSwap V3 concentrated
 *         liquidity position and issues ERC20 shares representing pro-rata ownership of it.
 *         Registered as a Moolah provider so it can supply and withdraw collateral on behalf of
 *         users without requiring per-user Moolah authorization.
 *
 * Architecture:
 *   - Shares (this contract's ERC20 token) are the Moolah collateral token for the market.
 *   - On deposit:  tokens → V3 liquidity → mint shares → Moolah.supplyCollateral(onBehalf)
 *   - On withdraw: Moolah.withdrawCollateral → burn shares → remove V3 liquidity → tokens to receiver
 *   - On liquidation: Moolah sends shares to liquidator; liquidator calls redeemShares()
 *   - Fees are compounded into the position before every deposit/withdraw/maintenance operation.
 *   - Only Moolah may transfer shares (prevents bypassing the vault on withdrawal).
 *
 * Extension points (overridden by pool/asset-specific subclasses):
 *   - _afterCollateralChange(id, account): hook called after deposit / withdraw / liquidation,
 *     e.g. to mirror the position into an external reward system.
 *   - peek / getTokenConfig / receive: virtual so subclasses can specialize pricing and native
 *     token acceptance.
 *
 * Dependencies:
 *   lib/lista-v3 (submodule)             - IListaV3Factory / IListaV3Pool interfaces.
 *   lib/lista-dao-contracts.git (submod) - audited 0.8 math libs TickMath + LiquidityAmounts.
 *   src/provider/interfaces/INonfungiblePositionManager.sol - minimal local NPM interface.
 */
abstract contract V3Provider is
  ERC4626Upgradeable,
  UUPSUpgradeable,
  AccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  IOracle,
  IV3Provider
{
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;

  /* ─────────────────────────── immutables ─────────────────────────── */

  /// @dev Moolah lending core
  IMoolah public immutable MOOLAH;

  /// @dev Uniswap V3 / PancakeSwap V3 NonfungiblePositionManager
  INonfungiblePositionManager public immutable POSITION_MANAGER;

  /// @dev V3 pool address for TOKEN0/TOKEN1/FEE, derived from NPM factory in constructor
  address public immutable POOL;

  /// @dev token0 of the V3 pool
  address public immutable TOKEN0;

  /// @dev token1 of the V3 pool
  address public immutable TOKEN1;

  /// @dev V3 pool fee tier (e.g. 500, 3000, 10000)
  uint24 public immutable FEE;

  /// @dev TWAP window in seconds for manipulation-resistant tick queries
  uint32 public immutable TWAP_PERIOD;

  /// @dev Decimal precision of TOKEN0 and TOKEN1, cached to avoid repeated external calls.
  uint8 public immutable DECIMALS0;
  uint8 public immutable DECIMALS1;

  /// @dev BSC wrapped native token. Users may send BNB directly; it is wrapped on entry
  ///      and unwrapped on exit when one of the pool tokens is WBNB.
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Resilient oracle used to price TOKEN0 and TOKEN1 individually (8-decimal USD)
  address public resilientOracle;

  /// @dev tokenId of the V3 NFT position held by this contract; 0 means no position yet
  uint256 public tokenId;

  /// @dev Lower tick of the current position range
  int24 public tickLower;

  /// @dev Upper tick of the current position range
  int24 public tickUpper;

  /// @dev Idle TOKEN0 balance that arose from internal ratio mismatch during compounding.
  ///      Tracked separately to avoid sweeping arbitrary token donations.
  uint256 public idleToken0;

  /// @dev Idle TOKEN1 balance that arose from internal ratio mismatch during compounding.
  ///      Tracked separately to avoid sweeping arbitrary token donations.
  uint256 public idleToken1;

  /// @dev Reserved storage so future base-contract variables can be added without shifting
  ///      subclass storage. Reduce the array size when adding a new variable.
  uint256[50] private __gap;

  /* ───────────────────────────── events ───────────────────────────── */

  event Deposit(
    address indexed onBehalf,
    uint256 amount0Used,
    uint256 amount1Used,
    uint256 shares,
    Id indexed marketId
  );
  event Withdraw(
    address indexed onBehalf,
    uint256 shares,
    uint256 amount0,
    uint256 amount1,
    address receiver,
    Id indexed marketId
  );
  event SharesWithdrawn(address indexed onBehalf, uint256 shares, address receiver, Id indexed marketId);
  event SharesSupplied(address indexed supplier, address indexed onBehalf, uint256 shares, Id indexed marketId);
  event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 amount0, uint256 amount1, address receiver);
  event Compounded(uint256 fees0, uint256 fees1, uint128 liquidityAdded);
  event Rebalanced(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper, uint256 newTokenId);

  /* ───────────────────────────── errors ───────────────────────────── */

  error ZeroAddress();
  error TokenOrderInvalid();
  error ZeroFee();
  error ZeroTwapPeriod();
  error PoolDoesNotExist();
  error InvalidTickRange();
  error OnlyMoolah();
  error InvalidCollateralToken();
  error PoolHasNoWBNB();
  error ZeroAmounts();
  error ZeroLiquidity();
  error ZeroShares();
  error Unauthorized();
  error InsufficientShares();
  error InvalidMarket();
  error BnbTransferFailed();
  error NotWBNB();
  error StandardEntryDisabled();

  /* ─────────────────────────── constructor ────────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _moolah,
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) {
    if (_moolah == address(0)) revert ZeroAddress();
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

    MOOLAH = IMoolah(_moolah);
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

  /**
   * @dev Shared initializer for subclasses. Subclasses expose an external `initialize`
   *      guarded by the `initializer` modifier and forward to this.
   * @param _admin            Default admin (can upgrade, grant roles)
   * @param _manager          Manager role (can configure provider-level risk controls)
   * @param _bot              Bot address granted BOT role (can trigger rebalance)
   * @param _resilientOracle  Resilient oracle for pricing TOKEN0 and TOKEN1
   * @param _tickLower        Initial position lower tick
   * @param _tickUpper        Initial position upper tick
   * @param _name             ERC20 name for shares token
   * @param _symbol           ERC20 symbol for shares token
   */
  function __V3Provider_init(
    address _admin,
    address _manager,
    address _bot,
    address _resilientOracle,
    int24 _tickLower,
    int24 _tickUpper,
    string calldata _name,
    string calldata _symbol
  ) internal onlyInitializing {
    if (_admin == address(0) || _manager == address(0) || _bot == address(0) || _resilientOracle == address(0)) {
      revert ZeroAddress();
    }
    if (_tickLower >= _tickUpper) revert InvalidTickRange();

    __ERC20_init(_name, _symbol);
    __ERC4626_init(IERC20(WBNB)); // ERC-4626 shell: numéraire asset is WBNB (BNB)
    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _setRoleAdmin(BOT, MANAGER);
    _grantRole(BOT, _bot);

    resilientOracle = _resilientOracle;
    tickLower = _tickLower;
    tickUpper = _tickUpper;
  }

  /* ──────────────────── ERC20 transfer restrictions ───────────────── */

  /// @dev Only Moolah may transfer shares. This prevents users from transferring
  ///      shares directly without going through withdraw(), which would orphan V3 liquidity.
  function transfer(address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    _transfer(msg.sender, to, value);
    return true;
  }

  /// @dev Only Moolah may call transferFrom (e.g. when pulling collateral on supplyCollateral).
  function transferFrom(address from, address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    _transfer(from, to, value);
    return true;
  }

  /* ─────────────────────── core user functions ────────────────────── */

  /**
   * @notice Deposit TOKEN0 and TOKEN1, add them to the V3 position, mint shares,
   *         and supply those shares as Moolah collateral on behalf of `onBehalf`.
   * @param marketParams   Moolah market (collateralToken must equal address(this))
   * @param amount0Desired Max TOKEN0 to deposit
   * @param amount1Desired Max TOKEN1 to deposit
   * @param amount0Min     Min TOKEN0 accepted after slippage (for V3 mint/increase)
   * @param amount1Min     Min TOKEN1 accepted after slippage (for V3 mint/increase)
   * @param onBehalf       Moolah position owner to credit collateral to
   * @return shares        Shares minted to represent this deposit
   * @return amount0Used   Actual TOKEN0 consumed by the V3 pool
   * @return amount1Used   Actual TOKEN1 consumed by the V3 pool
   */
  function deposit(
    MarketParams calldata marketParams,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address onBehalf
  ) external payable nonReentrant returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (onBehalf == address(0)) revert ZeroAddress();

    // ── Native token handling ──────────────────────────────────────────
    // If the caller sends BNB, wrap it and use it in place of the pool token
    // that equals WBNB.  Pull the other token via transferFrom as usual.
    // Idle always stays in wrapped (ERC-20) form; only the entry boundary wraps.
    uint256 _amount0Desired = amount0Desired;
    uint256 _amount1Desired = amount1Desired;

    if (msg.value > 0) {
      if (!(TOKEN0 == WBNB || TOKEN1 == WBNB)) revert PoolHasNoWBNB();
      if (TOKEN0 == WBNB) {
        _amount0Desired = msg.value;
      } else {
        _amount1Desired = msg.value;
      }
      IWBNB(WBNB).deposit{ value: msg.value }();
    }

    if (_amount0Desired == 0 && _amount1Desired == 0) revert ZeroAmounts();

    // Reject upfront if the supplied amounts yield zero liquidity at the current price.
    // This catches one-sided deposits in the wrong direction (e.g. token0-only when price
    // is above tickUpper) before any tokens are pulled from the caller.
    {
      (uint160 sqrtPriceX96, , , , , , ) = IListaV3Pool(POOL).slot0();
      if (
        LiquidityAmounts.getLiquidityForAmounts(
          sqrtPriceX96,
          TickMath.getSqrtRatioAtTick(tickLower),
          TickMath.getSqrtRatioAtTick(tickUpper),
          _amount0Desired,
          _amount1Desired
        ) == 0
      ) {
        revert ZeroLiquidity();
      }
    }

    // Pull ERC-20 tokens from caller.
    // Skip whichever side was funded by msg.value (already wrapped and held by this contract).
    if (_amount0Desired > 0 && !(TOKEN0 == WBNB && msg.value > 0)) {
      IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), _amount0Desired);
    }
    if (_amount1Desired > 0 && !(TOKEN1 == WBNB && msg.value > 0)) {
      IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), _amount1Desired);
    }

    // Compound pending fees before computing share ratio so existing holders
    // capture accrued fees before new shares dilute them.
    _collectAndCompound();

    uint128 liquidityBefore = _getPositionLiquidity();
    uint256 supplyBefore = totalSupply();

    uint128 liquidityAdded;
    if (tokenId == 0) {
      // No position exists yet — mint a fresh V3 NFT.
      (tokenId, liquidityAdded, amount0Used, amount1Used) = V3PositionLib.mint(
        POSITION_MANAGER,
        TOKEN0,
        TOKEN1,
        FEE,
        tickLower,
        tickUpper,
        _amount0Desired,
        _amount1Desired,
        amount0Min,
        amount1Min
      );

      // First depositor: shares 1:1 with liquidity units.
      shares = uint256(liquidityAdded);
    } else {
      // Existing position — increase liquidity.
      (liquidityAdded, amount0Used, amount1Used) = V3PositionLib.increaseLiquidity(
        POSITION_MANAGER,
        TOKEN0,
        TOKEN1,
        tokenId,
        _amount0Desired,
        _amount1Desired,
        amount0Min,
        amount1Min
      );

      // Subsequent depositors: proportional to liquidity contributed vs pre-deposit total.
      if (supplyBefore == 0 || liquidityBefore == 0) {
        shares = uint256(liquidityAdded);
      } else {
        shares = (uint256(liquidityAdded) * supplyBefore) / uint256(liquidityBefore);
      }
    }

    if (shares == 0) revert ZeroShares();

    // Refund any tokens not consumed by the V3 pool (ratio mismatch).
    // WBNB refunds are unwrapped back to BNB before sending.
    uint256 refund0 = _amount0Desired - amount0Used;
    uint256 refund1 = _amount1Desired - amount1Used;
    if (refund0 > 0) _sendToken(TOKEN0, refund0, payable(msg.sender));
    if (refund1 > 0) _sendToken(TOKEN1, refund1, payable(msg.sender));

    // Mint shares to this contract, then grant Moolah a one-time allowance so
    // supplyCollateral can pull them. Our transferFrom restricts the caller to
    // Moolah, so _approve is used internally to set the allowance.
    _mint(address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);

    emit Deposit(onBehalf, amount0Used, amount1Used, shares, marketParams.id());
  }

  /**
   * @notice Withdraw shares from Moolah, remove the proportional V3 liquidity,
   *         and return TOKEN0/TOKEN1 to `receiver`.
   * @dev Caller must be `onBehalf` or authorized via MOOLAH.isAuthorized().
   * @param marketParams Moolah market (collateralToken must equal address(this))
   * @param shares       Number of shares to redeem
   * @param minAmount0   Min TOKEN0 to receive (slippage guard)
   * @param minAmount1   Min TOKEN1 to receive (slippage guard)
   * @param onBehalf     Owner of the Moolah collateral position
   * @param receiver     Address to send TOKEN0/TOKEN1 to
   */
  function withdraw(
    MarketParams calldata marketParams,
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address onBehalf,
    address receiver
  ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (shares == 0) revert ZeroShares();
    if (receiver == address(0)) revert ZeroAddress();
    if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

    // Moolah decrements position.collateral and transfers shares to address(this).
    // Our transfer() allows msg.sender == MOOLAH, so this succeeds.
    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));

    _afterCollateralChange(marketParams.id(), onBehalf);

    _collectAndCompound();

    (amount0, amount1) = _burnSharesAndRemoveLiquidity(shares, minAmount0, minAmount1, receiver);

    emit Withdraw(onBehalf, shares, amount0, amount1, receiver, marketParams.id());
  }

  /**
   * @notice Withdraw provider shares from Moolah collateral without redeeming the underlying V3 position.
   * @dev Caller must be `onBehalf` or authorized via MOOLAH.isAuthorized().
   *      This enables moving the same vLP shares to another Moolah market through supplyShares().
   * @param marketParams Moolah market (collateralToken must equal address(this))
   * @param shares       Number of shares to withdraw from the Moolah collateral position
   * @param onBehalf     Owner of the Moolah collateral position
   * @param receiver     Address to receive the provider shares
   */
  function withdrawShares(
    MarketParams calldata marketParams,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external nonReentrant {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (shares == 0) revert ZeroShares();
    if (receiver == address(0)) revert ZeroAddress();
    if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));

    _afterCollateralChange(marketParams.id(), onBehalf);

    _transfer(address(this), receiver, shares);

    emit SharesWithdrawn(onBehalf, shares, receiver, marketParams.id());
  }

  /**
   * @notice Supply wallet-held provider shares as Moolah collateral.
   * @dev Useful after withdrawShares() when moving vLP collateral between isolated markets.
   * @param marketParams Moolah market (collateralToken must equal address(this))
   * @param shares       Number of wallet-held provider shares to supply
   * @param onBehalf     Moolah position owner to credit collateral to
   */
  function supplyShares(MarketParams calldata marketParams, uint256 shares, address onBehalf) external nonReentrant {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (shares == 0) revert ZeroShares();
    if (onBehalf == address(0)) revert ZeroAddress();
    if (balanceOf(msg.sender) < shares) revert InsufficientShares();

    _transfer(msg.sender, address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);

    emit SharesSupplied(msg.sender, onBehalf, shares, marketParams.id());
  }

  /**
   * @notice Redeem shares already held by the caller (typically a liquidator that
   *         received shares from Moolah during liquidation) for TOKEN0/TOKEN1.
   * @param shares     Number of shares to redeem
   * @param minAmount0 Min TOKEN0 to receive (slippage guard)
   * @param minAmount1 Min TOKEN1 to receive (slippage guard)
   * @param receiver   Address to send TOKEN0/TOKEN1 to
   */
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
    if (shares == 0) revert ZeroShares();
    if (receiver == address(0)) revert ZeroAddress();
    if (balanceOf(msg.sender) < shares) revert InsufficientShares();

    _collectAndCompound();

    // Transfer shares from caller to this contract so _burnSharesAndRemoveLiquidity
    // can burn from address(this). We use the internal _transfer to bypass the
    // Moolah-only restriction (caller holds their own shares).
    _transfer(msg.sender, address(this), shares);

    (amount0, amount1) = _burnSharesAndRemoveLiquidity(shares, minAmount0, minAmount1, receiver);

    emit SharesRedeemed(msg.sender, shares, amount0, amount1, receiver);
  }

  /* ──────────────────── Moolah provider callback ──────────────────── */

  /**
   * @dev Called by Moolah after a liquidation event. Runs the _afterCollateralChange hook so
   *      subclasses can resync external state. Moolah already transferred the seized shares to
   *      the liquidator via transfer().
   */
  function liquidate(Id id, address borrower) external {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    if (MOOLAH.idToMarketParams(id).collateralToken != address(this)) revert InvalidMarket();
    _afterCollateralChange(id, borrower);
  }

  /* ───────────────────────── view functions ───────────────────────── */

  /**
   * @notice Total TOKEN0 and TOKEN1 represented by the vault at the current spot price.
   *         Includes amounts locked in the V3 position, uncollected fees (tokensOwed),
   *         and any idle token balances held by this contract.
   * @dev    Uses slot0 — suitable for display and bot decisions, NOT for the lending oracle.
   *         peek() uses the TWAP price to resist manipulation; see _getTotalAmountsAt.
   */
  function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
    (uint160 sqrtPriceX96, , , , , , ) = IListaV3Pool(POOL).slot0();
    return _getTotalAmountsAt(sqrtPriceX96);
  }

  /**
   * @notice Simulates a redemption and returns the token amounts a holder would receive
   *         for burning `shares` at the current pool price.
   *         Use this to compute tight `minAmount0`/`minAmount1` before calling
   *         `withdraw` or `redeemShares`:
   *
   *         (uint256 exp0, uint256 exp1) = provider.previewRedeem(shares);
   *         uint256 min0 = exp0 * 995 / 1000;  // 0.5 % slippage tolerance
   *         uint256 min1 = exp1 * 995 / 1000;
   *         provider.withdraw(marketParams, shares, min0, min1, onBehalf, receiver);
   *
   * @param shares  Number of provider shares to redeem.
   * @return amount0  TOKEN0 the caller would receive (≥ minAmount0 to pass slippage guard).
   * @return amount1  TOKEN1 the caller would receive (≥ minAmount1 to pass slippage guard).
   */
  function previewRedeemUnderlying(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
    uint256 supply = totalSupply();
    if (supply == 0 || shares == 0) return (0, 0);

    uint128 totalLiquidity = _getPositionLiquidity();
    uint128 liquidityToRemove = uint128((uint256(totalLiquidity) * shares) / supply);

    (uint160 sqrtPriceX96, , , , , , ) = IListaV3Pool(POOL).slot0();
    (amount0, amount1) = _getAmountsForLiquidity(
      sqrtPriceX96,
      TickMath.getSqrtRatioAtTick(tickLower),
      TickMath.getSqrtRatioAtTick(tickUpper),
      liquidityToRemove
    );
  }

  /**
   * @notice Simulates a deposit and returns the token amounts that would actually be consumed
   *         plus the liquidity that would be minted, given desired input amounts.
   *         Use this to compute tight `amount0Min`/`amount1Min` before calling `deposit`:
   *
   *         (uint128 liq, uint256 exp0, uint256 exp1) = provider.previewDeposit(des0, des1);
   *         uint256 min0 = exp0 * 995 / 1000;  // 0.5 % slippage tolerance
   *         uint256 min1 = exp1 * 995 / 1000;
   *         provider.deposit(marketParams, des0, des1, min0, min1, onBehalf);
   *
   * @param amount0Desired  Amount of TOKEN0 the caller intends to supply.
   * @param amount1Desired  Amount of TOKEN1 the caller intends to supply.
   * @return liquidity      Liquidity units that would be added to the position.
   * @return amount0        TOKEN0 that would actually be consumed (≤ amount0Desired).
   * @return amount1        TOKEN1 that would actually be consumed (≤ amount1Desired).
   */
  function previewDepositAmounts(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    (uint160 sqrtPriceX96, , , , , , ) = IListaV3Pool(POOL).slot0();
    uint160 sqrtRatioLower = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtRatioUpper = TickMath.getSqrtRatioAtTick(tickUpper);

    liquidity = LiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      sqrtRatioLower,
      sqrtRatioUpper,
      amount0Desired,
      amount1Desired
    );
    (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtRatioLower, sqrtRatioUpper, liquidity);
  }

  /// @dev Returns the TOKEN field required by the IProvider interface.
  ///      For a V3Provider, the "token" is this contract itself (the shares ERC20).
  function TOKEN() external view returns (address) {
    return address(this);
  }

  /* ─────────────────────── ERC-4626 shell ─────────────────────────── */

  /// @notice ERC-4626 total managed assets, denominated in the vault asset (WBNB / BNB).
  /// @dev    Equals the position's BNB value: with the resilient oracle pricing slisBNB as
  ///         BNB_price × exchangeRate, `USD_value / WBNB_price` collapses to
  ///         `WBNB_amt + slisBNB_amt × exchangeRate` (PRD §4.5). WBNB has 18 decimals, so the
  ///         8-decimal USD value scaled by 1e18 and divided by the 8-decimal WBNB price yields an
  ///         18-decimal WBNB amount. convertToShares/convertToAssets derive from this and totalSupply.
  function totalAssets() public view override returns (uint256) {
    uint256 assetPrice = IOracle(resilientOracle).peek(asset()); // 8 decimals
    if (assetPrice == 0) return 0;
    return (_positionValueUsd() * 1e18) / assetPrice;
  }

  /// @dev The single-asset ERC-4626 entry points are disabled — this is a two-token LP vault.
  ///      Use the two-token deposit(marketParams,…) / withdraw(marketParams,…) / redeemShares().
  function deposit(uint256, address) public pure override returns (uint256) {
    revert StandardEntryDisabled();
  }

  function mint(uint256, address) public pure override returns (uint256) {
    revert StandardEntryDisabled();
  }

  function withdraw(uint256, address, address) public pure override returns (uint256) {
    revert StandardEntryDisabled();
  }

  function redeem(uint256, address, address) public pure override returns (uint256) {
    revert StandardEntryDisabled();
  }

  /* ─────────────────────── IOracle implementation ─────────────────── */

  /**
   * @notice Returns the USD price (8 decimals) for a given token.
   *         - If token == address(this): prices provider shares as
   *           (total0 × price0 + total1 × price1) / totalSupply.
   *         - Otherwise: delegates directly to the resilient oracle.
   *
   * @dev    Token composition is derived from the TWAP tick (not slot0) so a single-block
   *         AMM price manipulation cannot inflate the reported collateral value. Subclasses may
   *         override to use an exchange-rate-implied price instead of the pool TWAP.
   */
  function peek(address token) external view virtual override returns (uint256) {
    if (token != address(this)) {
      return IOracle(resilientOracle).peek(token);
    }

    uint256 supply = totalSupply();
    if (supply == 0) return 0;

    // shares are 18-decimal; return 8-decimal price per share
    return (_positionValueUsd() * 1e18) / supply;
  }

  /// @dev Total position value in 8-decimal USD, with leg composition taken at the TWAP price
  ///      (manipulation-resistant). Shared by peek() and totalAssets().
  function _positionValueUsd() internal view returns (uint256) {
    (uint256 total0, uint256 total1) = _getTotalAmountsAt(_valuationSqrtPriceX96());
    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8 decimals
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8 decimals
    return (total0 * price0) / (10 ** DECIMALS0) + (total1 * price1) / (10 ** DECIMALS1);
  }

  /// @dev sqrtPriceX96 used to value the position for the lending oracle (peek / totalAssets /
  ///      getUserBalanceInBnb). Base uses the pool TWAP. Subclasses override to use an
  ///      exchange-rate-implied price so a pool-trade cannot move the reported collateral value.
  function _valuationSqrtPriceX96() internal view virtual returns (uint160) {
    return TickMath.getSqrtRatioAtTick(getTwapTick());
  }

  /**
   * @notice Returns the TokenConfig for a given token.
   *         - If token == address(this): registers this contract as the primary oracle
   *           so the resilient oracle can delegate share pricing back to us.
   *         - Otherwise: delegates to the resilient oracle.
   */
  function getTokenConfig(address token) external view virtual override returns (TokenConfig memory) {
    if (token != address(this)) {
      return IOracle(resilientOracle).getTokenConfig(token);
    }
    return
      TokenConfig({
        asset: token,
        oracles: [address(this), address(0), address(0)],
        enableFlagsForOracles: [true, false, false],
        timeDeltaTolerance: 0
      });
  }

  /// @notice Returns the TWAP tick for POOL over TWAP_PERIOD seconds.
  ///         Public (not external) so peek() can call it directly.
  function getTwapTick() public view returns (int24 twapTick) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = TWAP_PERIOD;
    secondsAgos[1] = 0;

    (int56[] memory tickCumulatives, ) = IListaV3Pool(POOL).observe(secondsAgos);

    int56 delta = tickCumulatives[1] - tickCumulatives[0];
    twapTick = int24(delta / int56(uint56(TWAP_PERIOD)));
    if (delta < 0 && (delta % int56(uint56(TWAP_PERIOD)) != 0)) twapTick--;
  }

  /* ────────────────────────── extension hooks ─────────────────────── */

  /// @dev Hook invoked after deposit / withdraw / liquidation with the affected (market, account).
  ///      Base is a no-op; subclasses override to mirror the position into external systems.
  function _afterCollateralChange(Id id, address account) internal virtual {}

  /* ─────────────────────────── internals ──────────────────────────── */

  /// @dev Collect accrued fees from the position and re-add them plus any previously
  ///      idle tokens (from prior ratio mismatches) as liquidity.
  ///      Idle amounts are tracked in storage rather than read from balanceOf() to
  ///      avoid sweeping arbitrary token donations into the position.
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

    // Track leftover from ratio mismatch so it's swept on the next compound.
    idleToken0 = toCompound0 - used0;
    idleToken1 = toCompound1 - used1;

    emit Compounded(toCompound0, toCompound1, liquidityAdded);
  }

  /// @dev Collect all pending fees without compounding (used before rebalance).
  ///      Returns the amounts collected so callers can track totals without balanceOf.
  function _collectAll() internal returns (uint256 collected0, uint256 collected1) {
    if (tokenId == 0) return (0, 0);
    (collected0, collected1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);
  }

  /// @dev Burn `shares` held by address(this), remove proportional V3 liquidity,
  ///      collect the resulting tokens to this contract, then forward to `receiver`
  ///      — unwrapping WBNB to native BNB along the way.
  function _burnSharesAndRemoveLiquidity(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) internal returns (uint256 amount0, uint256 amount1) {
    uint256 supply = totalSupply();
    uint128 totalLiquidity = _getPositionLiquidity();

    // Compute liquidity to remove proportionally to shares being redeemed.
    uint128 liquidityToRemove = uint128((uint256(totalLiquidity) * shares) / supply);

    _burn(address(this), shares);

    if (liquidityToRemove > 0) {
      V3PositionLib.decreaseLiquidity(POSITION_MANAGER, tokenId, liquidityToRemove, minAmount0, minAmount1);

      // Collect to address(this) so we can unwrap WBNB before forwarding.
      (amount0, amount1) = V3PositionLib.collectAll(POSITION_MANAGER, tokenId);

      if (amount0 > 0) _sendToken(TOKEN0, amount0, payable(receiver));
      if (amount1 > 0) _sendToken(TOKEN1, amount1, payable(receiver));
    }
  }

  /// @dev Transfer `token` to `to`.  If `token == WBNB`, unwrap first and send native BNB;
  ///      otherwise send as ERC-20.
  ///      Idle tokens (idleToken0/1) always stay in wrapped ERC-20 form; this helper
  ///      is only called at the exit boundary (withdraw / redeemShares / deposit refund).
  function _sendToken(address token, uint256 amount, address payable to) internal {
    if (token == WBNB) {
      IWBNB(WBNB).withdraw(amount);
      (bool ok, ) = to.call{ value: amount }("");
      if (!ok) revert BnbTransferFailed();
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }

  /// @dev Accepts native BNB sent by WBNB during unwrap. Subclasses may widen the allowed senders.
  receive() external payable virtual {
    if (msg.sender != WBNB) revert NotWBNB();
  }

  /// @dev Returns the current liquidity of the managed V3 position.
  function _getPositionLiquidity() internal view returns (uint128 liquidity) {
    if (tokenId == 0) return 0;
    (, , , , , , , liquidity, , , , ) = POSITION_MANAGER.positions(tokenId);
  }

  /// @dev True if the sender may act on behalf of `onBehalf`.
  function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
    return msg.sender == onBehalf || MOOLAH.isAuthorized(onBehalf, msg.sender);
  }

  /* ──────── Uniswap V3 liquidity math (via lista-dao-contracts) ─────── */

  /// @dev Shared implementation for getTotalAmounts() and peek(). Callers supply the
  ///      sqrtPriceX96 so each can use the price appropriate for its purpose:
  ///      slot0 for display/bots, TWAP for the lending oracle.
  function _getTotalAmountsAt(uint160 sqrtPriceX96) internal view returns (uint256 total0, uint256 total1) {
    if (tokenId == 0) return (0, 0);

    (, , , , , , , uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) = POSITION_MANAGER.positions(
      tokenId
    );

    (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(
      sqrtPriceX96,
      TickMath.getSqrtRatioAtTick(tickLower),
      TickMath.getSqrtRatioAtTick(tickUpper),
      liquidity
    );

    // Add uncollected fees and internally-tracked idle tokens (ratio mismatch leftovers).
    // Using idleToken0/1 instead of balanceOf() prevents donated tokens from inflating
    // the share price reported by peek().
    total0 = amount0 + uint256(tokensOwed0) + idleToken0;
    total1 = amount1 + uint256(tokensOwed1) + idleToken1;
  }

  /// @dev Computes token amounts for a given liquidity position at sqrtPriceX96.
  ///      Delegates to LiquidityAmounts.getAmountsForLiquidity (lista-dao-contracts, audited 0.8).
  function _getAmountsForLiquidity(
    uint160 sqrtPriceX96,
    uint160 sqrtRatioAX96,
    uint160 sqrtRatioBX96,
    uint128 liquidity
  ) internal pure returns (uint256 amount0, uint256 amount1) {
    return LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
  }

  /* ──────────────────────── upgrade guard ─────────────────────────── */

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

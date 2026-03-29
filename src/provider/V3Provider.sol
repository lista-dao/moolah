// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TickMath } from "../dex/v3/core/libraries/TickMath.sol";
import { SqrtPriceMath } from "../dex/v3/core/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "../dex/v3/periphery/libraries/LiquidityAmounts.sol";

import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";

import { INonfungiblePositionManager } from "../dex/v3/periphery/interfaces/INonfungiblePositionManager.sol";
import { IListaV3Factory } from "../dex/v3/core/interfaces/IListaV3Factory.sol";
import { IListaV3Pool } from "../dex/v3/core/interfaces/IListaV3Pool.sol";
import { IWBNB } from "./interfaces/IWBNB.sol";
import { IV3Provider } from "./interfaces/IV3Provider.sol";
import { ISlisBNBxMinter } from "../utils/interfaces/ISlisBNBx.sol";

/**
 * @title V3Provider
 * @author Lista DAO
 * @notice Manages a single Uniswap V3 / PancakeSwap V3 concentrated liquidity position.
 *         Issues ERC20 shares representing pro-rata ownership of the position.
 *         Registered as a Moolah provider so it can supply and withdraw collateral
 *         on behalf of users without requiring per-user Moolah authorization.
 *
 * Architecture:
 *   - Shares (this contract's ERC20 token) are the Moolah collateral token for the market.
 *   - On deposit:  tokens → V3 liquidity → mint shares → Moolah.supplyCollateral(onBehalf)
 *   - On withdraw: Moolah.withdrawCollateral → burn shares → remove V3 liquidity → tokens to receiver
 *   - On liquidation: Moolah sends shares to liquidator; liquidator calls redeemShares()
 *   - Fees are compounded into the position before every deposit/withdraw/rebalance.
 *   - Only Moolah may transfer shares (prevents bypassing the vault on withdrawal).
 *
 * Dependencies (add to lib/ or remappings):
 *   uniswap/v3-core  - TickMath
 */
contract V3Provider is
  ERC20Upgradeable,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
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

  /// @dev user account > market id > amount of collateral(shares) deposited
  mapping(address => mapping(Id => uint256)) public userMarketDeposit;

  /// @dev user account > total amount of collateral(shares) deposited
  mapping(address => uint256) public userTotalDeposit;

  /// @dev slisBNBxMinter address
  address public slisBNBxMinter;

  /// @dev Maximum allowed absolute tick deviation between slot0 and TWAP.
  ///      When non-zero, rebalance() reverts if |spotTick - twapTick| exceeds this value.
  ///      Default 0 = no guard (backwards compatible).
  uint24 public maxTickDeviation;

  /// @dev Virtual address used by the resilient oracle to price native BNB.
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* ───────────────────────────── events ───────────────────────────── */

  event SlisBNBxMinterChanged(address indexed minter);
  event MaxTickDeviationChanged(uint24 maxTickDeviation);

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
  event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 amount0, uint256 amount1, address receiver);
  event Compounded(uint256 fees0, uint256 fees1, uint128 liquidityAdded);
  event Rebalanced(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper, uint256 newTokenId);

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
    require(_moolah != address(0), "zero address");
    require(_positionManager != address(0), "zero address");
    require(_token0 != address(0) && _token1 != address(0), "zero address");
    require(_token0 < _token1, "token0 must be < token1");
    require(_fee > 0, "zero fee");
    require(_twapPeriod > 0, "zero twap period");

    address _pool = IListaV3Factory(INonfungiblePositionManager(_positionManager).factory()).getPool(
      _token0,
      _token1,
      _fee
    );
    require(_pool != address(0), "pool does not exist");

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
   * @param _admin            Default admin (can upgrade, grant roles)
   * @param _manager          Manager role (can rebalance position range)
   * @param _bot              Bot address granted BOT role (can trigger rebalance)
   * @param _resilientOracle  Resilient oracle for pricing TOKEN0 and TOKEN1
   * @param _tickLower        Initial position lower tick
   * @param _tickUpper        Initial position upper tick
   * @param _name             ERC20 name for shares token
   * @param _symbol           ERC20 symbol for shares token
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _resilientOracle,
    int24 _tickLower,
    int24 _tickUpper,
    string calldata _name,
    string calldata _symbol
  ) external initializer {
    require(
      _admin != address(0) && _manager != address(0) && _bot != address(0) && _resilientOracle != address(0),
      "zero address"
    );
    require(_tickLower < _tickUpper, "invalid tick range");

    __ERC20_init(_name, _symbol);
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
  function transfer(address to, uint256 value) public override returns (bool) {
    require(msg.sender == address(MOOLAH), "only moolah");
    _transfer(msg.sender, to, value);
    return true;
  }

  /// @dev Only Moolah may call transferFrom (e.g. when pulling collateral on supplyCollateral).
  function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    require(msg.sender == address(MOOLAH), "only moolah");
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
    require(marketParams.collateralToken == address(this), "invalid collateral token");
    require(onBehalf != address(0), "zero address");

    // ── Native token handling ──────────────────────────────────────────
    // If the caller sends BNB, wrap it and use it in place of the pool token
    // that equals WBNB.  Pull the other token via transferFrom as usual.
    // Idle always stays in wrapped (ERC-20) form; only the entry boundary wraps.
    uint256 _amount0Desired = amount0Desired;
    uint256 _amount1Desired = amount1Desired;

    if (msg.value > 0) {
      require(TOKEN0 == WBNB || TOKEN1 == WBNB, "pool has no WBNB");
      if (TOKEN0 == WBNB) {
        _amount0Desired = msg.value;
      } else {
        _amount1Desired = msg.value;
      }
      IWBNB(WBNB).deposit{ value: msg.value }();
    }

    require(_amount0Desired > 0 || _amount1Desired > 0, "zero amounts");

    // Reject upfront if the supplied amounts yield zero liquidity at the current price.
    // This catches one-sided deposits in the wrong direction (e.g. token0-only when price
    // is above tickUpper) before any tokens are pulled from the caller.
    {
      (uint160 sqrtPriceX96, , , , , , ) = IListaV3Pool(POOL).slot0();
      require(
        LiquidityAmounts.getLiquidityForAmounts(
          sqrtPriceX96,
          TickMath.getSqrtRatioAtTick(tickLower),
          TickMath.getSqrtRatioAtTick(tickUpper),
          _amount0Desired,
          _amount1Desired
        ) > 0,
        "zero liquidity"
      );
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
      IERC20(TOKEN0).safeIncreaseAllowance(address(POSITION_MANAGER), _amount0Desired);
      IERC20(TOKEN1).safeIncreaseAllowance(address(POSITION_MANAGER), _amount1Desired);

      (tokenId, liquidityAdded, amount0Used, amount1Used) = POSITION_MANAGER.mint(
        INonfungiblePositionManager.MintParams({
          token0: TOKEN0,
          token1: TOKEN1,
          fee: FEE,
          tickLower: tickLower,
          tickUpper: tickUpper,
          amount0Desired: _amount0Desired,
          amount1Desired: _amount1Desired,
          amount0Min: amount0Min,
          amount1Min: amount1Min,
          recipient: address(this),
          deadline: block.timestamp
        })
      );

      // First depositor: shares 1:1 with liquidity units.
      shares = uint256(liquidityAdded);
    } else {
      // Existing position — increase liquidity.
      IERC20(TOKEN0).safeIncreaseAllowance(address(POSITION_MANAGER), _amount0Desired);
      IERC20(TOKEN1).safeIncreaseAllowance(address(POSITION_MANAGER), _amount1Desired);

      (liquidityAdded, amount0Used, amount1Used) = POSITION_MANAGER.increaseLiquidity(
        INonfungiblePositionManager.IncreaseLiquidityParams({
          tokenId: tokenId,
          amount0Desired: _amount0Desired,
          amount1Desired: _amount1Desired,
          amount0Min: amount0Min,
          amount1Min: amount1Min,
          deadline: block.timestamp
        })
      );

      // Subsequent depositors: proportional to liquidity contributed vs pre-deposit total.
      if (supplyBefore == 0 || liquidityBefore == 0) {
        shares = uint256(liquidityAdded);
      } else {
        shares = (uint256(liquidityAdded) * supplyBefore) / uint256(liquidityBefore);
      }
    }

    require(shares > 0, "zero shares");

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

    _syncPosition(marketParams.id(), onBehalf);

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
    require(marketParams.collateralToken == address(this), "invalid collateral token");
    require(shares > 0, "zero shares");
    require(receiver != address(0), "zero address");
    require(_isSenderAuthorized(onBehalf), "unauthorized");

    // Moolah decrements position.collateral and transfers shares to address(this).
    // Our transfer() allows msg.sender == MOOLAH, so this succeeds.
    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));

    _syncPosition(marketParams.id(), onBehalf);

    _collectAndCompound();

    (amount0, amount1) = _burnSharesAndRemoveLiquidity(shares, minAmount0, minAmount1, receiver);

    emit Withdraw(onBehalf, shares, amount0, amount1, receiver, marketParams.id());
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
    require(shares > 0, "zero shares");
    require(receiver != address(0), "zero address");
    require(balanceOf(msg.sender) >= shares, "insufficient shares");

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
   * @dev Called by Moolah after a liquidation event.
   *      Syncs the borrower's deposit tracking and triggers slisBNBx rebalance if configured.
   *      Moolah already transferred the seized shares to the liquidator via transfer().
   */
  function liquidate(Id id, address borrower) external {
    require(msg.sender == address(MOOLAH), "only moolah");
    require(MOOLAH.idToMarketParams(id).collateralToken == address(this), "invalid market");
    _syncPosition(id, borrower);
  }

  /* ───────────────────── manager: rebalance range ─────────────────── */

  /**
   * @notice Move the position to a new tick range. Collects all fees, removes all
   *         liquidity, burns the old NFT, and mints a new position at the new ticks.
   *         Share count is unchanged — each share now represents the new range.
   * @dev    Caller must hold MANAGER role. A price movement between decreaseLiquidity
   *         and the new mint is the primary slippage risk; minAmount0/minAmount1 guard against it.
   * @param _tickLower      New lower tick
   * @param _tickUpper      New upper tick
   * @param minAmount0      Min TOKEN0 to receive when removing old liquidity
   * @param minAmount1      Min TOKEN1 to receive when removing old liquidity
   * @param amount0Desired  TOKEN0 to reinvest into the new position. Must not exceed
   *                        the total internally collected (fees + idle + removed liquidity).
   *                        Pass type(uint256).max to reinvest everything.
   * @param amount1Desired  TOKEN1 to reinvest into the new position. Same semantics.
   */
  function rebalance(
    int24 _tickLower,
    int24 _tickUpper,
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external onlyRole(BOT) nonReentrant {
    require(_tickLower < _tickUpper, "invalid tick range");

    // Guard: prevent rebalance when spot diverges too far from TWAP.
    if (maxTickDeviation > 0) {
      (, int24 spotTick, , , , , ) = IListaV3Pool(POOL).slot0();
      int24 twapTick = getTwapTick();
      int24 delta = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
      require(uint24(delta) <= maxTickDeviation, "twap deviation too high");
    }

    int24 oldTickLower = tickLower;
    int24 oldTickUpper = tickUpper;

    // 1. Collect all fees; track amounts explicitly to avoid balanceOf donation surface.
    (uint256 total0, uint256 total1) = _collectAll();

    // Add previously idle tokens from compound ratio mismatches.
    total0 += idleToken0;
    total1 += idleToken1;
    idleToken0 = 0;
    idleToken1 = 0;

    // 2. Remove all existing liquidity.
    if (tokenId != 0) {
      uint128 liquidity = _getPositionLiquidity();
      if (liquidity > 0) {
        POSITION_MANAGER.decreaseLiquidity(
          INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: minAmount0,
            amount1Min: minAmount1,
            deadline: block.timestamp
          })
        );
      }
      // Collect removed liquidity back to this contract; accumulate into tracked totals.
      (uint256 removed0, uint256 removed1) = POSITION_MANAGER.collect(
        INonfungiblePositionManager.CollectParams({
          tokenId: tokenId,
          recipient: address(this),
          amount0Max: type(uint128).max,
          amount1Max: type(uint128).max
        })
      );
      total0 += removed0;
      total1 += removed1;

      POSITION_MANAGER.burn(tokenId);
      tokenId = 0;
    }

    // 3. Update range.
    tickLower = _tickLower;
    tickUpper = _tickUpper;

    // 4. Re-mint with caller-specified amounts (capped to internally available).
    //    This lets the BOT pre-compute the optimal ratio for the new tick range,
    //    minimising idle remainder. Excess stays in idleToken0/1 for next compound.
    uint256 toMint0 = amount0Desired > total0 ? total0 : amount0Desired;
    uint256 toMint1 = amount1Desired > total1 ? total1 : amount1Desired;

    if (toMint0 > 0 || toMint1 > 0) {
      IERC20(TOKEN0).safeIncreaseAllowance(address(POSITION_MANAGER), toMint0);
      IERC20(TOKEN1).safeIncreaseAllowance(address(POSITION_MANAGER), toMint1);

      (uint256 newTokenId, , uint256 used0, uint256 used1) = POSITION_MANAGER.mint(
        INonfungiblePositionManager.MintParams({
          token0: TOKEN0,
          token1: TOKEN1,
          fee: FEE,
          tickLower: _tickLower,
          tickUpper: _tickUpper,
          amount0Desired: toMint0,
          amount1Desired: toMint1,
          amount0Min: 0,
          amount1Min: 0,
          recipient: address(this),
          deadline: block.timestamp
        })
      );
      tokenId = newTokenId;

      // Any leftover (caller under-specified or ratio mismatch) tracked for next compound.
      idleToken0 = total0 - used0;
      idleToken1 = total1 - used1;
    } else {
      // Nothing to mint; park everything as idle.
      idleToken0 = total0;
      idleToken1 = total1;
    }

    emit Rebalanced(oldTickLower, oldTickUpper, _tickLower, _tickUpper, tokenId);
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
  function previewRedeem(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
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
  function previewDeposit(
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
  ///      For V3Provider, the "token" is this contract itself (the shares ERC20).
  function TOKEN() external view returns (address) {
    return address(this);
  }

  /* ─────────────────────── IOracle implementation ─────────────────── */

  /**
   * @notice Returns the USD price (8 decimals) for a given token.
   *         - If token == address(this): prices V3Provider shares as
   *           (total0 × price0 + total1 × price1) / totalSupply.
   *         - Otherwise: delegates directly to the resilient oracle.
   *
   * @dev    Token composition is derived from the TWAP tick (not slot0) so a single-block
   *         AMM price manipulation cannot inflate the reported collateral value.
   *         The maxTickDeviation guard on rebalance() prevents rebalancing while spot
   *         diverges far from TWAP, which would cause a phantom share-price discontinuity.
   *         pool.observe() reverts when the pool lacks TWAP_PERIOD seconds of history,
   *         which in turn reverts peek() — intentionally blocking borrows until the market
   *         has seasoned.
   */
  function peek(address token) external view override returns (uint256) {
    if (token != address(this)) {
      return IOracle(resilientOracle).peek(token);
    }

    uint256 supply = totalSupply();
    if (supply == 0) return 0;

    uint160 sqrtTwapX96 = TickMath.getSqrtRatioAtTick(getTwapTick());
    (uint256 total0, uint256 total1) = _getTotalAmountsAt(sqrtTwapX96);

    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8 decimals
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8 decimals

    uint256 totalValue = (total0 * price0) / (10 ** DECIMALS0) + (total1 * price1) / (10 ** DECIMALS1);

    // shares are 18-decimal; return 8-decimal price per share
    return (totalValue * 1e18) / supply;
  }

  /**
   * @notice Returns the TokenConfig for a given token.
   *         - If token == address(this): registers this contract as the primary oracle
   *           so the resilient oracle can delegate share pricing back to us.
   *         - Otherwise: delegates to the resilient oracle.
   */
  function getTokenConfig(address token) external view override returns (TokenConfig memory) {
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

  /**
   * @notice Returns the TWAP tick for POOL over TWAP_PERIOD seconds.
   *         Useful for bots to cross-check whether the current slot0 tick deviates
   *         significantly from the TWAP before triggering a rebalance.
   *         Public (not external) so peek() can call it directly.
   */
  function getTwapTick() public view returns (int24 twapTick) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = TWAP_PERIOD;
    secondsAgos[1] = 0;

    (int56[] memory tickCumulatives, ) = IListaV3Pool(POOL).observe(secondsAgos);

    int56 delta = tickCumulatives[1] - tickCumulatives[0];
    twapTick = int24(delta / int56(uint56(TWAP_PERIOD)));
    if (delta < 0 && (delta % int56(uint56(TWAP_PERIOD)) != 0)) twapTick--;
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

    (uint256 total0, uint256 total1) = getTotalAmounts();

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
    require(MOOLAH.idToMarketParams(id).collateralToken == address(this), "invalid market");
    _syncPosition(id, account);
  }

  /**
   * @notice Batch sync multiple users across multiple markets.
   * @param ids      Array of market Ids.
   * @param accounts Array of user addresses (parallel to ids).
   */
  function bulkSyncUserBalance(Id[] calldata ids, address[] calldata accounts) external {
    require(ids.length == accounts.length, "length mismatch");
    for (uint256 i = 0; i < accounts.length; i++) {
      require(MOOLAH.idToMarketParams(ids[i]).collateralToken == address(this), "invalid market");
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

  /// @notice Set the maximum allowed tick deviation between slot0 and TWAP for rebalance().
  ///         Pass 0 to disable the guard.
  function setMaxTickDeviation(uint24 _maxTickDeviation) external onlyRole(MANAGER) {
    maxTickDeviation = _maxTickDeviation;
    emit MaxTickDeviationChanged(_maxTickDeviation);
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  /// @dev Reads the user's current Moolah collateral for `id`, diffs against the last
  ///      recorded snapshot in `userMarketDeposit`, updates `userTotalDeposit`, then
  ///      calls `slisBNBxMinter.rebalance(account)` if a minter is configured.
  ///      Callers that have already validated the market (deposit, withdraw) skip the
  ///      idToMarketParams check; liquidate() validates before calling this.
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

  /// @dev Collect accrued fees from the position and re-add them plus any previously
  ///      idle tokens (from prior ratio mismatches) as liquidity.
  ///      Idle amounts are tracked in storage rather than read from balanceOf() to
  ///      avoid sweeping arbitrary token donations into the position.
  function _collectAndCompound() internal {
    if (tokenId == 0) return;

    (uint256 fees0, uint256 fees1) = POSITION_MANAGER.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );

    uint256 toCompound0 = fees0 + idleToken0;
    uint256 toCompound1 = fees1 + idleToken1;

    if (toCompound0 == 0 && toCompound1 == 0) return;

    IERC20(TOKEN0).safeIncreaseAllowance(address(POSITION_MANAGER), toCompound0);
    IERC20(TOKEN1).safeIncreaseAllowance(address(POSITION_MANAGER), toCompound1);

    (uint128 liquidityAdded, uint256 used0, uint256 used1) = POSITION_MANAGER.increaseLiquidity(
      INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: tokenId,
        amount0Desired: toCompound0,
        amount1Desired: toCompound1,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      })
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
    (collected0, collected1) = POSITION_MANAGER.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );
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
      POSITION_MANAGER.decreaseLiquidity(
        INonfungiblePositionManager.DecreaseLiquidityParams({
          tokenId: tokenId,
          liquidity: liquidityToRemove,
          amount0Min: minAmount0,
          amount1Min: minAmount1,
          deadline: block.timestamp
        })
      );

      // Collect to address(this) so we can unwrap WBNB before forwarding.
      (amount0, amount1) = POSITION_MANAGER.collect(
        INonfungiblePositionManager.CollectParams({
          tokenId: tokenId,
          recipient: address(this),
          amount0Max: type(uint128).max,
          amount1Max: type(uint128).max
        })
      );

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
      require(ok, "BNB transfer failed");
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }

  /// @dev Accepts native BNB sent by WBNB during unwrap.
  receive() external payable {
    require(msg.sender == WBNB, "not WBNB");
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

  /* ──────── Uniswap V3 liquidity math (via v3-core libraries) ──────── */

  /// @dev Shared implementation for getTotalAmounts() and peek(). Callers supply the
  ///      sqrtPriceX96 so each can use the price appropriate for its purpose:
  ///      slot0 for display/bots, TWAP for the lending oracle.
  function _getTotalAmountsAt(uint160 sqrtPriceX96) private view returns (uint256 total0, uint256 total1) {
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
  ///      Delegates to SqrtPriceMath from uniswap/v3-core for overflow-safe arithmetic.
  function _getAmountsForLiquidity(
    uint160 sqrtPriceX96,
    uint160 sqrtRatioAX96,
    uint160 sqrtRatioBX96,
    uint128 liquidity
  ) internal pure returns (uint256 amount0, uint256 amount1) {
    if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

    if (sqrtPriceX96 <= sqrtRatioAX96) {
      // Current price below range: position is fully TOKEN0.
      amount0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
    } else if (sqrtPriceX96 < sqrtRatioBX96) {
      // Current price inside range.
      amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, false);
      amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, false);
    } else {
      // Current price above range: position is fully TOKEN1.
      amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
    }
  }

  /* ──────────────────────── upgrade guard ─────────────────────────── */

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

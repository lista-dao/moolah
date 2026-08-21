// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";

import { IWBNB } from "../interfaces/IWBNB.sol";
import { IV3Provider } from "../interfaces/IV3Provider.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";

/**
 * @title V3Provider
 * @author Lista DAO
 * @notice Generic, abstract VAULT for a V3 LP collateral position. Issues ERC-4626 vLP shares that
 *         are the Moolah collateral token, wires deposit/withdraw to Moolah, and delegates ALL DEX
 *         interaction (NFT custody, NPM/pool math, rebalance) to a V3DexAdapter. Share pricing for
 *         Moolah lives in a separate SlisBNBV3ProviderOracle (this contract is NOT an IOracle).
 *
 * Architecture (3-contract split):
 *   - V3Provider (this)   : ERC-4626 shares + Moolah wiring + share accounting. Holds no NFT.
 *   - V3DexAdapter        : sole NFT custodian + all NPM/pool writes + raw-NAV/composition views.
 *   - SlisBNBV3ProviderOracle    : Moolah `market.oracle`; prices the share off the adapter's fair view.
 *
 * Token flow:
 *   - deposit:  user → vault (pull/wrap) → adapter (transfer) → addLiquidity (adapter refunds unused to user)
 *   - withdraw: adapter.removeLiquidity sends underlying directly to receiver (no double hop)
 *
 * Extension point:
 *   - _afterCollateralChange(id, account): hook after deposit / withdraw / liquidation.
 */
abstract contract V3Provider is
  ERC4626Upgradeable,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  IV3Provider
{
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;

  /* ─────────────────────────── immutables ─────────────────────────── */

  /// @dev Moolah lending core.
  IMoolah public immutable MOOLAH;

  /// @dev DEX adapter that custodies the V3 NFT and performs all pool interaction.
  address public immutable ADAPTER;

  /// @dev Pool tokens (mirrored from the adapter for deposit/pricing). token0 < token1.
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  uint8 public immutable DECIMALS0;
  uint8 public immutable DECIMALS1;

  /// @dev Wrapped-native token (WBNB on BSC, WETH on Ethereum), mirrored from the adapter. Native sent
  ///      on deposit is wrapped to this before forwarding.
  address public immutable WRAPPED_NATIVE;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /// @dev Denominator for `maxRebalanceLossBp` — parts-per-million (ppm).
  uint256 internal constant LOSS_DENOM = 1e6;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Resilient oracle pricing TOKEN0/TOKEN1 (8-decimal USD), used for totalAssets().
  address public resilientOracle;

  /// @dev Decimal precision of the ERC-4626 accounting asset.
  uint8 public accountingAssetDecimals;

  /// @dev Per-rebalance fair-NAV loss cap, in ppm (LOSS_DENOM = 1e6). A single rebalance may not
  ///      drop the position's fair USD value by more than this. Default 20_000 = 2%.
  uint256 public maxRebalanceLossBp;
  /// @dev Per-UTC-day cumulative rebalance loss cap, 8-decimal USD. Default 1000e8.
  uint256 public maxDailyLossUsd;
  /// @dev UTC day (block.timestamp / 1 days) the rebalance-loss accumulator currently tracks.
  uint256 public dailyLossDay;
  /// @dev Cumulative rebalance loss (8-decimal USD) recorded so far for `dailyLossDay`.
  uint256 public dailyLossAccum;

  /// @dev Gate on the deposit entry point only. Disabled by default; flip on for a gated launch.
  bool public depositWhitelistEnabled;
  mapping(address => bool) public depositWhitelist;

  /// @dev Reserved storage for future base variables (keep subclass storage stable on upgrade).
  uint256[44] private __gap;

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
  event MaxRebalanceLossBpChanged(uint256 maxRebalanceLossBp);
  event MaxDailyLossUsdChanged(uint256 maxDailyLossUsd);
  event DepositWhitelistEnabledChanged(bool enabled);
  event DepositWhitelistChanged(address indexed account, bool allowed);
  event RebalanceDailyLossAccrued(uint256 indexed day, uint256 loss, uint256 accum);

  /* ───────────────────────────── errors ───────────────────────────── */

  error ZeroAddress();
  error InvalidCollateralToken();
  error PoolHasNoWrappedNative();
  error ZeroAmounts();
  error ZeroShares();
  error Unauthorized();
  error InsufficientShares();
  error OnlyMoolah();
  error NotWhitelisted();
  error InvalidMarket();
  error StandardEntryDisabled();
  error BnbTransferFailed();
  error NotAdapter();
  error RebalanceLossTooHigh();
  error DailyLossExceeded();
  error OracleZero();
  error InvalidParam();
  error InsufficientAmount();

  /// @dev Fixed-point scale for the deposit composition-ratio math.
  uint256 private constant WAD = 1e18;

  /* ─────────────────────────── constructor ────────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _moolah, address _adapter) {
    if (_moolah == address(0) || _adapter == address(0)) revert ZeroAddress();
    MOOLAH = IMoolah(_moolah);
    ADAPTER = _adapter;
    TOKEN0 = IV3DexAdapter(_adapter).TOKEN0();
    TOKEN1 = IV3DexAdapter(_adapter).TOKEN1();
    DECIMALS0 = IV3DexAdapter(_adapter).DECIMALS0();
    DECIMALS1 = IV3DexAdapter(_adapter).DECIMALS1();
    WRAPPED_NATIVE = IV3DexAdapter(_adapter).WRAPPED_NATIVE();
    _disableInitializers();
  }

  /* ─────────────────────────── initializer ────────────────────────── */

  function __V3Provider_init(
    address _admin,
    address _manager,
    address _bot,
    address _resilientOracle,
    address _accountingAsset,
    string calldata _name,
    string calldata _symbol
  ) internal onlyInitializing {
    if (
      _admin == address(0) ||
      _manager == address(0) ||
      _bot == address(0) ||
      _resilientOracle == address(0) ||
      _accountingAsset == address(0)
    ) {
      revert ZeroAddress();
    }

    __ERC20_init(_name, _symbol);
    __ERC4626_init(IERC20(_accountingAsset));
    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _setRoleAdmin(BOT, MANAGER);
    _grantRole(BOT, _bot);

    resilientOracle = _resilientOracle;
    accountingAssetDecimals = IERC20Metadata(_accountingAsset).decimals();

    maxRebalanceLossBp = 20_000; // 2% (ppm) — per-rebalance fair-NAV loss cap
    maxDailyLossUsd = 1000e8; // 1000 USD/day — cumulative rebalance loss cap
    emit MaxRebalanceLossBpChanged(maxRebalanceLossBp);
    emit MaxDailyLossUsdChanged(maxDailyLossUsd);
  }

  /// @notice Turn the deposit whitelist on or off. onlyRole MANAGER.
  function setDepositWhitelistEnabled(bool enabled) external onlyRole(MANAGER) {
    depositWhitelistEnabled = enabled;
    emit DepositWhitelistEnabledChanged(enabled);
  }

  /// @notice Allow or disallow accounts on the deposit whitelist. onlyRole MANAGER.
  /// @dev    Removing an account only closes new deposits — it never blocks that account's withdraw,
  ///         redeem or liquidation.
  function setDepositWhitelist(address[] calldata accounts, bool allowed) external onlyRole(MANAGER) {
    for (uint256 i; i < accounts.length; ++i) {
      if (accounts[i] == address(0)) revert ZeroAddress();
      depositWhitelist[accounts[i]] = allowed;
      emit DepositWhitelistChanged(accounts[i], allowed);
    }
  }

  /* ──────────────────── ERC20 transfer restrictions ───────────────── */

  /// @dev Only Moolah may transfer shares (prevents orphaning the position by moving collateral out).
  function transfer(address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    _transfer(msg.sender, to, value);
    return true;
  }

  function transferFrom(
    address from,
    address to,
    uint256 value
  ) public override(ERC20Upgradeable, IERC20) returns (bool) {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    _spendAllowance(from, msg.sender, value); // decrement the granted allowance like a standard ERC20 pull
    _transfer(from, to, value);
    return true;
  }

  /* ─────────────────────── core user functions ────────────────────── */

  /// @inheritdoc IV3Provider
  function deposit(
    MarketParams calldata marketParams,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minShares,
    address onBehalf
  ) external payable nonReentrant returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (onBehalf == address(0)) revert ZeroAddress();
    // Check both: gating only msg.sender would let a whitelisted caller open a position for anyone.
    if (depositWhitelistEnabled && (!depositWhitelist[msg.sender] || !depositWhitelist[onBehalf]))
      revert NotWhitelisted();

    uint256 _amount0Desired = amount0Desired;
    uint256 _amount1Desired = amount1Desired;

    // Wrap any native coin into the wrapped-native token and use it for that leg.
    if (msg.value > 0) {
      if (!(TOKEN0 == WRAPPED_NATIVE || TOKEN1 == WRAPPED_NATIVE)) revert PoolHasNoWrappedNative();
      if (TOKEN0 == WRAPPED_NATIVE) {
        _amount0Desired = msg.value;
      } else {
        _amount1Desired = msg.value;
      }
      IWBNB(WRAPPED_NATIVE).deposit{ value: msg.value }();
    }

    if (_amount0Desired == 0 && _amount1Desired == 0) revert ZeroAmounts();

    // Pull ERC-20 input (skip the side funded by msg.value, already wrapped here).
    if (_amount0Desired > 0 && !(TOKEN0 == WRAPPED_NATIVE && msg.value > 0)) {
      IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), _amount0Desired);
    }
    if (_amount1Desired > 0 && !(TOKEN1 == WRAPPED_NATIVE && msg.value > 0)) {
      IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), _amount1Desired);
    }

    // No inline compound: positionAmountsAt(fair) below already includes pending fees (simulated from
    // fee-growth deltas), so the composition snapshot is complete and existing holders keep their fees
    // without deploying liquidity here. Fees are deployed only via the BOT-gated, slippage-bounded
    // compound() / rebalance.
    uint256 supplyBefore = totalSupply();
    uint160 fairSqrtPriceX96 = IV3DexAdapter(ADAPTER).fairSqrtPriceX96();

    if (supplyBefore == 0) {
      // First deposit: no existing composition to match and no holders to dilute. Mint the initial NFT
      // position at spot and value it at fair via the oracle to set the opening share price. The
      // spot-vs-fair over-crediting this path guards against needs pre-existing idle/holders, so it
      // cannot occur on the first deposit; the first-depositor inflation surface is a separate concern.
      //
      // The addLiquidity refund is deliberately NOT sent to the depositor here (refundTo = this vault):
      // a native-BNB refund before shares are minted would expose a window where adapter NAV already
      // includes the new liquidity but totalSupply() is stale, letting a malicious depositor reenter and
      // read an inflated share price. The vault refunds the depositor only after _mint below.
      if (_amount0Desired > 0) IERC20(TOKEN0).safeTransfer(ADAPTER, _amount0Desired);
      if (_amount1Desired > 0) IERC20(TOKEN1).safeTransfer(ADAPTER, _amount1Desired);
      uint128 liquidityAdded;
      (liquidityAdded, amount0Used, amount1Used) = IV3DexAdapter(ADAPTER).addLiquidity(
        _amount0Desired,
        _amount1Desired,
        amount0Min,
        amount1Min,
        address(this)
      );
      (uint256 added0, uint256 added1) = IV3DexAdapter(ADAPTER).amountsForLiquidity(liquidityAdded, fairSqrtPriceX96);
      uint256 assetPrice = IOracle(resilientOracle).peek(asset()); // 8 decimals
      if (assetPrice > 0) {
        shares = (_amountsValueUsd(added0, added1) * (10 ** uint256(accountingAssetDecimals))) / assetPrice;
      }
    } else {
      // Subsequent deposit: issue shares purely proportional to the existing position
      // composition — never from a pool-spot mint re-valued at fair. Snapshot the composition at the
      // fair price (positionAmountsAt already includes idle inventory + collected fees), bind the deposit
      // to that ratio, and park the consumed tokens as IDLE rather than minting into the pool. The pool
      // spot price never enters share issuance, so the mint-at-spot / value-at-fair gap that let a
      // depositor be over-credited (with idle present) is eliminated. Value-conserving: the depositor
      // adds exactly `frac` of each composition leg and receives `frac` of the supply.
      // min(fair, spot) share credit + fair-pinned consumed amounts (see _quoteDeposit).
      (shares, amount0Used, amount1Used) = _quoteDeposit(supplyBefore, _amount0Desired, _amount1Desired);
      // Repurposed slippage guard: amount0Min/amount1Min are now the minimum of each leg that must be
      // consumed (the rest is refunded), protecting the depositor from an unexpected composition ratio.
      if (amount0Used < amount0Min || amount1Used < amount1Min) revert InsufficientAmount();

      // Park the consumed tokens into the adapter's idle inventory (deployed later by compound()).
      if (amount0Used > 0) IERC20(TOKEN0).safeTransfer(ADAPTER, amount0Used);
      if (amount1Used > 0) IERC20(TOKEN1).safeTransfer(ADAPTER, amount1Used);
      IV3DexAdapter(ADAPTER).creditIdle(amount0Used, amount1Used);
    }

    if (shares == 0) revert ZeroShares();
    // Caller-specified share-slippage floor. Protects a depositor from receiving fewer shares than their
    // contribution warrants — e.g. a first-depositor inflation attack that inflates the position via a
    // direct NPM.increaseLiquidity donation, or the fair composition shifting between the off-chain
    // preview and execution. Pass 0 to disable.
    if (shares < minShares) revert InsufficientShares();

    _mint(address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);

    emit Deposit(onBehalf, amount0Used, amount1Used, shares, marketParams.id());

    // Refund unused input to the depositor now that shares are minted and supplied (CEI): NAV and
    // totalSupply are consistent, so the (native-BNB) refund callback cannot inflate the share price.
    uint256 refund0 = _amount0Desired - amount0Used;
    uint256 refund1 = _amount1Desired - amount1Used;
    // The subsequent-deposit path leaves the WRAPPED_NATIVE leftover in the vault as WBNB, whereas the
    // first-deposit path already received it as native from the adapter's addLiquidity refund. _refund
    // sends the wrapped-native leg as native BNB, so normalize the subsequent case by unwrapping here.
    if (supplyBefore > 0) {
      if (TOKEN0 == WRAPPED_NATIVE && refund0 > 0) IWBNB(WRAPPED_NATIVE).withdraw(refund0);
      if (TOKEN1 == WRAPPED_NATIVE && refund1 > 0) IWBNB(WRAPPED_NATIVE).withdraw(refund1);
    }
    if (refund0 > 0) _refund(TOKEN0, refund0, msg.sender);
    if (refund1 > 0) _refund(TOKEN1, refund1, msg.sender);

    // NOTE: the subsequent-deposit path deliberately does NOT deploy the freshly-parked
    // idle into the pool here. Deposits enter as idle valued at the fair composition and are matched by
    // proportionally-minted shares, so the deposit is exactly value-conserving and never touches the pool
    // spot price. The idle is deployed later by the BOT-gated compound() (keeper cadence) or a rebalance,
    // both slippage-bounded. Deploying it inline here would mint at spot and realize a small IL shared by
    // all holders — a (tiny) dilution triggered by a new deposit.
  }

  /// @inheritdoc IV3Provider
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

    // No inline compound — deploying liquidity is BOT-gated. The health check still counts pending fees:
    // the oracle prices the share via positionAmountsAt(fair), which is fee-inclusive. removeLiquidity
    // below still collects the withdrawer's pro-rata fees.
    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));
    _afterCollateralChange(marketParams.id(), onBehalf);

    // CEI: burn before the adapter removes liquidity and pushes underlying to `receiver`, so
    // totalSupply stays consistent with the reduced position during the (native-BNB) callback —
    // otherwise the oracle would briefly under-price the share. Pass the pre-burn supply so the
    // liquidity-fraction math (shares/supply) is unchanged.
    uint256 supply = totalSupply();
    _burn(address(this), shares);
    (amount0, amount1) = IV3DexAdapter(ADAPTER).removeLiquidity(shares, supply, minAmount0, minAmount1, receiver);

    emit Withdraw(onBehalf, shares, amount0, amount1, receiver, marketParams.id());
  }

  /// @inheritdoc IV3Provider
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

    // No inline compound — deploying liquidity is BOT-gated. The health check still counts pending fees:
    // the oracle prices the share via positionAmountsAt(fair), which is fee-inclusive.
    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));
    _afterCollateralChange(marketParams.id(), onBehalf);

    _transfer(address(this), receiver, shares);
    emit SharesWithdrawn(onBehalf, shares, receiver, marketParams.id());
  }

  /// @inheritdoc IV3Provider
  function supplyShares(MarketParams calldata marketParams, uint256 shares, address onBehalf) external nonReentrant {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (shares == 0) revert ZeroShares();
    if (onBehalf == address(0)) revert ZeroAddress();
    if (balanceOf(msg.sender) < shares) revert InsufficientShares();

    // No inline compound — deploying liquidity is BOT-gated. The health check still counts pending fees:
    // the oracle prices the share via positionAmountsAt(fair), which is fee-inclusive.
    _transfer(msg.sender, address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);
    emit SharesSupplied(msg.sender, onBehalf, shares, marketParams.id());
  }

  /// @inheritdoc IV3Provider
  /// @dev Liquidation-critical path: no protocol value floor — caller's minAmount0/1 is the only
  ///      guard (a hard floor here would brick atomic liquidation).
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
    if (shares == 0) revert ZeroShares();
    if (receiver == address(0)) revert ZeroAddress();
    if (balanceOf(msg.sender) < shares) revert InsufficientShares();

    // No inline compound — fee re-deployment is BOT-gated (compound() / rebalance). removeLiquidity below
    // still collects the caller's pro-rata fees.
    // CEI: burn the caller's shares before the adapter sends underlying to `receiver` (see withdraw).
    uint256 supply = totalSupply();
    _burn(msg.sender, shares);
    (amount0, amount1) = IV3DexAdapter(ADAPTER).removeLiquidity(shares, supply, minAmount0, minAmount1, receiver);

    emit SharesRedeemed(msg.sender, shares, amount0, amount1, receiver);
  }

  /* ──────────────────── Moolah provider callback ──────────────────── */

  function liquidate(Id id, address borrower) external {
    if (msg.sender != address(MOOLAH)) revert OnlyMoolah();
    if (MOOLAH.idToMarketParams(id).collateralToken != address(this)) revert InvalidMarket();
    _afterCollateralChange(id, borrower);
  }

  /* ───────────────────────── view functions ───────────────────────── */

  /// @inheritdoc IV3Provider
  function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
    return IV3DexAdapter(ADAPTER).positionAmountsAt(IV3DexAdapter(ADAPTER).spotSqrtPriceX96());
  }

  /// @inheritdoc IV3Provider
  /// @dev The managed position's token composition valued at the FAIR (manipulation-resistant) price,
  ///      inclusive of idle inventory and collected fees. This is the ratio a subsequent deposit binds
  ///      to; front-ends should size the two deposit legs in this ratio to minimise the refund. Returns
  ///      (0, 0) before the first deposit (no position yet) — use previewDepositAmounts for that case.
  function getFairComposition() public view returns (uint256 total0, uint256 total1) {
    return IV3DexAdapter(ADAPTER).positionAmountsAt(IV3DexAdapter(ADAPTER).fairSqrtPriceX96());
  }

  /// @notice Simulate a redemption of `shares` at the current pool price (for tight minAmount0/1).
  function previewRedeemUnderlying(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
    return IV3DexAdapter(ADAPTER).previewRemoveLiquidity(shares, totalSupply());
  }

  /// @notice Simulate a deposit at the current pool price (for tight amount0Min/amount1Min).
  /// @notice Preview the token amounts a deposit would consume.
  /// @dev For the first deposit (totalSupply == 0) this previews the pool mint (liquidity + amounts at
  ///      spot). For subsequent deposits it previews the composition-ratio binding used by deposit():
  ///      the amounts are `frac` of the current fair composition, where `frac = min(d0/T0, d1/T1)`, and
  ///      `liquidity` is returned as 0 since the deposit is parked as idle rather than minted.
  function previewDepositAmounts(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    if (totalSupply() == 0) {
      return IV3DexAdapter(ADAPTER).previewAddLiquidity(amount0Desired, amount1Desired);
    }
    (uint256 t0, uint256 t1) = IV3DexAdapter(ADAPTER).positionAmountsAt(IV3DexAdapter(ADAPTER).fairSqrtPriceX96());
    uint256 frac;
    if (t0 == 0) {
      frac = t1 == 0 ? 0 : (amount1Desired * WAD) / t1;
    } else if (t1 == 0) {
      frac = (amount0Desired * WAD) / t0;
    } else {
      uint256 f0 = (amount0Desired * WAD) / t0;
      uint256 f1 = (amount1Desired * WAD) / t1;
      frac = f0 < f1 ? f0 : f1;
    }
    // Round UP, matching _quoteDeposit: the preview must report exactly what deposit() will consume.
    amount0 = (t0 * frac + WAD - 1) / WAD;
    amount1 = (t1 * frac + WAD - 1) / WAD;
  }

  /// @notice Preview the shares a deposit would mint — the exact min(fair, spot) credit deposit() uses.
  ///         Frontends size `minShares` off this (× a slippage tolerance). First deposit (supply == 0)
  ///         previews the oracle-valued opening mint.
  /// @param amount0Desired token0 offered by the depositor.
  /// @param amount1Desired token1 offered by the depositor.
  /// @return shares shares deposit() would mint for these amounts.
  function previewDepositShares(uint256 amount0Desired, uint256 amount1Desired) external view returns (uint256 shares) {
    uint256 supplyBefore = totalSupply();
    if (supplyBefore > 0) {
      (shares, , ) = _quoteDeposit(supplyBefore, amount0Desired, amount1Desired);
      return shares;
    }
    (uint128 liquidity, , ) = IV3DexAdapter(ADAPTER).previewAddLiquidity(amount0Desired, amount1Desired);
    (uint256 added0, uint256 added1) = IV3DexAdapter(ADAPTER).amountsForLiquidity(
      liquidity,
      IV3DexAdapter(ADAPTER).fairSqrtPriceX96()
    );
    uint256 assetPrice = IOracle(resilientOracle).peek(asset());
    if (assetPrice > 0)
      shares = (_amountsValueUsd(added0, added1) * (10 ** uint256(accountingAssetDecimals))) / assetPrice;
  }

  /// @notice Given a desired token0 amount, the token1 amount that pairs with it at the current fair
  ///         composition ratio, so a subsequent deposit consumes both legs fully (minimal refund).
  /// @dev    amount1 = amount0 * T1 / T0, where (T0, T1) = getFairComposition(). Reverts once fair has
  ///         drifted past tickUpper (no token0 leg); deposits are then closed in every shape until the
  ///         BOT recenters. Symmetric below tickLower. First deposit: use previewDepositAmounts.
  function previewDepositForToken0(uint256 amount0) external view returns (uint256 amount1) {
    (uint256 t0, uint256 t1) = getFairComposition();
    if (t0 == 0) revert ZeroAmounts();
    amount1 = (amount0 * t1) / t0;
  }

  /// @notice Mirror of previewDepositForToken0: the token0 amount that pairs with a desired token1
  ///         amount at the current fair composition ratio (amount0 = amount1 * T0 / T1).
  function previewDepositForToken1(uint256 amount1) external view returns (uint256 amount0) {
    (uint256 t0, uint256 t1) = getFairComposition();
    if (t1 == 0) revert ZeroAmounts();
    amount0 = (amount1 * t0) / t1;
  }

  /// @notice IProvider hook — the "token" is this shares contract itself.
  function TOKEN() external view returns (address) {
    return address(this);
  }

  /* ─────────────────────── ERC-4626 shell ─────────────────────────── */

  /// @notice ERC-4626 total managed assets, in the accounting asset's units.
  /// @dev    Reads the adapter's FAIR composition (manipulation-resistant) priced via the resilient
  ///         oracle, divided by the accounting asset's USD price.
  function totalAssets() public view override returns (uint256) {
    uint256 assetPrice = IOracle(resilientOracle).peek(asset()); // 8 decimals
    if (assetPrice == 0) return 0;
    return (_positionValueUsd() * (10 ** uint256(accountingAssetDecimals))) / assetPrice;
  }

  /// @dev Total position value in 8-decimal USD at the adapter's fair price (raw, no haircut).
  function _positionValueUsd() internal view returns (uint256) {
    (uint256 total0, uint256 total1) = IV3DexAdapter(ADAPTER).positionAmountsAt(
      IV3DexAdapter(ADAPTER).fairSqrtPriceX96()
    );
    return _amountsValueUsd(total0, total1);
  }

  /// @dev Value token0/token1 amounts as 8-decimal USD through the resilient oracle.
  function _amountsValueUsd(uint256 amount0, uint256 amount1) internal view returns (uint256) {
    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8 decimals
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8 decimals
    // Fail closed: a broken feed on either leg (price 0) must revert, not silently value the position on
    // one leg (which would under-price the collateral and enable unfair liquidation / over-borrow).
    if (price0 == 0 || price1 == 0) revert OracleZero();
    return (amount0 * price0) / (10 ** DECIMALS0) + (amount1 * price1) / (10 ** DECIMALS1);
  }

  /// @dev WAD-fraction of a composition covered by given amounts, on the binding (smaller) leg:
  ///      min(amount0/comp0, amount1/comp1) × WAD. Single-sided composition binds on the present leg;
  ///      all-zero composition reverts (div-by-zero) — callers guard it.
  /// @param amount0 token0 amount being priced.
  /// @param amount1 token1 amount being priced.
  /// @param comp0   token0 of the composition priced against.
  /// @param comp1   token1 of the composition priced against.
  /// @return WAD-scaled fraction (1e18 == the full composition).
  function _compositionFractionWad(
    uint256 amount0,
    uint256 amount1,
    uint256 comp0,
    uint256 comp1
  ) internal pure returns (uint256) {
    if (comp0 == 0) return (amount1 * WAD) / comp1;
    if (comp1 == 0) return (amount0 * WAD) / comp0;
    uint256 frac0 = (amount0 * WAD) / comp0;
    uint256 frac1 = (amount1 * WAD) / comp1;
    return frac0 < frac1 ? frac0 : frac1;
  }

  /// @dev Quote a subsequent deposit (supplyBefore > 0): consumed amounts pinned to the FAIR composition
  ///      (rounded up); shares = min(sharesFair, sharesSpot), the spot quote re-pricing the SAME consumed
  ///      amounts. Withdraw settles at spot, so the min caps the credit at what a spot exit can back
  ///      (closes the deposit-withdraw cycle). Shared with previewDepositShares — preview can't drift.
  /// @param supplyBefore   share supply before this deposit.
  /// @param amount0Desired token0 offered by the depositor.
  /// @param amount1Desired token1 offered by the depositor.
  /// @return shares      shares to mint = min(fair, spot).
  /// @return amount0Used token0 consumed and parked to idle (rest refunded).
  /// @return amount1Used token1 consumed and parked to idle (rest refunded).
  function _quoteDeposit(
    uint256 supplyBefore,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) internal view returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
    (uint256 t0, uint256 t1) = IV3DexAdapter(ADAPTER).positionAmountsAt(IV3DexAdapter(ADAPTER).fairSqrtPriceX96());
    if (_amountsValueUsd(t0, t1) == 0) revert ZeroShares();

    uint256 frac = _compositionFractionWad(amount0Desired, amount1Desired, t0, t1);
    amount0Used = (t0 * frac + WAD - 1) / WAD;
    amount1Used = (t1 * frac + WAD - 1) / WAD;

    uint256 sharesFair = (supplyBefore * frac) / WAD;
    (uint256 s0, uint256 s1) = IV3DexAdapter(ADAPTER).positionAmountsAt(IV3DexAdapter(ADAPTER).spotSqrtPriceX96());
    uint256 sharesSpot = (s0 == 0 && s1 == 0)
      ? type(uint256).max // degenerate spot composition: do not let it lower the credit
      : (supplyBefore * _compositionFractionWad(amount0Used, amount1Used, s0, s1)) / WAD;
    shares = sharesFair < sharesSpot ? sharesFair : sharesSpot;
  }

  /// @dev Single-asset ERC-4626 entry is disabled — this is a two-token LP vault. Use the two-token
  ///      deposit(marketParams,…) / withdraw(marketParams,…) / redeemShares().
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

  /* ────────────────────────── extension hooks ─────────────────────── */

  /// @dev Hook invoked after deposit / withdraw / liquidation with the affected (market, account).
  function _afterCollateralChange(Id id, address account) internal virtual {}

  /* ─────────────────────────── internals ──────────────────────────── */

  function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
    return msg.sender == onBehalf || MOOLAH.isAuthorized(onBehalf, msg.sender);
  }

  /// @dev Forward a deposit refund to the depositor. The wrapped-native leg is already unwrapped to
  ///      native coin by the adapter when it refunds to this vault, so it is paid out as native coin.
  function _refund(address token, uint256 amount, address to) internal {
    if (token == WRAPPED_NATIVE) {
      (bool ok, ) = payable(to).call{ value: amount }("");
      if (!ok) revert BnbTransferFailed();
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }

  /// @dev Accept native BNB only from the adapter (its WBNB-unwrap refund) or from the wrapped-native
  ///      token itself (when this vault unwraps a subsequent-deposit WBNB leftover before refunding it
  ///      as native). No other sender may push native in; the vault's NAV is read from the adapter
  ///      composition, not its native balance, so an accepted transfer cannot distort share pricing.
  receive() external payable {
    if (msg.sender != ADAPTER && msg.sender != WRAPPED_NATIVE) revert NotAdapter();
  }

  /// @notice Collect accrued swap fees + idle and compound them back into the position.
  /// @dev BOT-gated with a caller-supplied slippage floor (amount0Min/amount1Min forwarded to the
  ///      adapter's increaseLiquidity). Adding CLAMM liquidity is the one operation that must not be
  ///      permissionless: a manipulated pool spot lets a caller force a bad-price re-add and sandwich it.
  ///      This is the sole liquidity-deploy path for accrued fees/idle (the other is BOT rebalance); no
  ///      user hot-path triggers it. Keeper runs this on a cadence.
  function compound(uint256 amount0Min, uint256 amount1Min) external onlyRole(BOT) nonReentrant {
    IV3DexAdapter(ADAPTER).collectAndCompound(amount0Min, amount1Min);
  }

  /* ─────────────────── rebalance loss guard (NAV + daily caps) ──────────────── */

  /// @notice Set the per-rebalance fair-NAV loss cap, in ppm (LOSS_DENOM = 1e6). onlyRole MANAGER.
  function setMaxRebalanceLossBp(uint256 _maxRebalanceLossBp) external onlyRole(MANAGER) {
    if (_maxRebalanceLossBp > LOSS_DENOM) revert InvalidParam();
    maxRebalanceLossBp = _maxRebalanceLossBp;
    emit MaxRebalanceLossBpChanged(_maxRebalanceLossBp);
  }

  /// @notice Set the per-UTC-day cumulative rebalance loss cap, 8-decimal USD. onlyRole MANAGER.
  function setMaxDailyLossUsd(uint256 _maxDailyLossUsd) external onlyRole(MANAGER) {
    maxDailyLossUsd = _maxDailyLossUsd;
    emit MaxDailyLossUsdChanged(_maxDailyLossUsd);
  }

  /// @dev Shared rebalance wrapper enforcing the value-neutrality guards, so a compromised BOT cannot
  ///      bleed the position regardless of the swapData / minLiquidity / minAmount it passes (the adapter
  ///      itself enforces the per-swap rate floor). Snapshots the position's FAIR USD value (never
  ///      pool spot) before/after the adapter recenter:
  ///        NAV cap — the fair NAV may not drop more than `maxRebalanceLossBp` (ppm) in one rebalance;
  ///        Daily cap — the cumulative daily loss may not exceed `maxDailyLossUsd` (loss only, profit does not
  ///             offset), per UTC day.
  ///      Fail-closed: if shares exist but the position values to 0, the resilient feed is broken and the
  ///      rebalance reverts rather than running unguarded.
  function _guardedRebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint160 targetSqrtPriceX96,
    uint256 expectedCenterRate,
    uint256 deadline,
    bytes calldata swapData
  ) internal {
    uint256 navBefore = _positionValueUsd();
    if (totalSupply() != 0 && navBefore == 0) revert OracleZero();

    IV3DexAdapter(ADAPTER).rebalance(
      minAmount0,
      minAmount1,
      minLiquidity,
      targetSqrtPriceX96,
      expectedCenterRate,
      deadline,
      swapData
    );

    uint256 navAfter = _positionValueUsd();

    if (navBefore != 0) {
      // Per-rebalance fair-NAV loss cap.
      if (navAfter * LOSS_DENOM < navBefore * (LOSS_DENOM - maxRebalanceLossBp)) revert RebalanceLossTooHigh();

      // Per-UTC-day cumulative loss cap (loss only; profit does not offset). NB: this is a FIXED UTC
      // window (not sliding): the worst case straddling 00:00 UTC is up to 2x
      // maxDailyLossUsd across the boundary. Accepted: it is a defense-in-depth backstop on top of the
      // per-swap and per-rebalance caps, and the pre-existing rate-drift guard throttles rebalance frequency.
      if (navAfter < navBefore) {
        uint256 loss = navBefore - navAfter;
        uint256 today = block.timestamp / 1 days;
        if (today != dailyLossDay) {
          dailyLossDay = today;
          dailyLossAccum = 0;
        }
        uint256 accum = dailyLossAccum + loss;
        if (accum > maxDailyLossUsd) revert DailyLossExceeded();
        dailyLossAccum = accum;
        emit RebalanceDailyLossAccrued(today, loss, accum);
      }
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

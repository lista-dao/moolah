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

import { IWBNB } from "./interfaces/IWBNB.sol";
import { IV3Provider } from "./interfaces/IV3Provider.sol";
import { IV3DexAdapter } from "./interfaces/IV3DexAdapter.sol";

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

  /// @dev BSC wrapped native token. BNB sent on deposit is wrapped to WBNB before forwarding.
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Resilient oracle pricing TOKEN0/TOKEN1 (8-decimal USD), used for totalAssets().
  address public resilientOracle;

  /// @dev Decimal precision of the ERC-4626 accounting asset.
  uint8 public accountingAssetDecimals;

  /// @dev Reserved storage for future base variables (keep subclass storage stable on upgrade).
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

  /* ───────────────────────────── errors ───────────────────────────── */

  error ZeroAddress();
  error InvalidCollateralToken();
  error PoolHasNoWBNB();
  error ZeroAmounts();
  error ZeroShares();
  error Unauthorized();
  error InsufficientShares();
  error OnlyMoolah();
  error InvalidMarket();
  error StandardEntryDisabled();

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
    address onBehalf
  ) external payable nonReentrant returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
    if (marketParams.collateralToken != address(this)) revert InvalidCollateralToken();
    if (onBehalf == address(0)) revert ZeroAddress();

    uint256 _amount0Desired = amount0Desired;
    uint256 _amount1Desired = amount1Desired;

    // Wrap any native BNB into WBNB and use it for the WBNB leg.
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

    // Pull ERC-20 input (skip the side funded by msg.value, already wrapped here).
    if (_amount0Desired > 0 && !(TOKEN0 == WBNB && msg.value > 0)) {
      IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), _amount0Desired);
    }
    if (_amount1Desired > 0 && !(TOKEN1 == WBNB && msg.value > 0)) {
      IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), _amount1Desired);
    }

    // Compound accrued fees first so existing holders capture them before new shares dilute.
    IV3DexAdapter(ADAPTER).collectAndCompound();

    uint256 totalValueBefore;
    uint256 supplyBefore = totalSupply();
    uint160 fairSqrtPriceX96 = IV3DexAdapter(ADAPTER).fairSqrtPriceX96();
    if (supplyBefore > 0) {
      (uint256 total0Before, uint256 total1Before) = IV3DexAdapter(ADAPTER).positionAmountsAt(fairSqrtPriceX96);
      totalValueBefore = _amountsValueUsd(total0Before, total1Before);
      if (totalValueBefore == 0) revert ZeroShares();
    }

    // Forward the input to the adapter, which adds liquidity and refunds unused to the depositor.
    if (_amount0Desired > 0) IERC20(TOKEN0).safeTransfer(ADAPTER, _amount0Desired);
    if (_amount1Desired > 0) IERC20(TOKEN1).safeTransfer(ADAPTER, _amount1Desired);

    uint128 liquidityAdded;
    (liquidityAdded, amount0Used, amount1Used) = IV3DexAdapter(ADAPTER).addLiquidity(
      _amount0Desired,
      _amount1Desired,
      amount0Min,
      amount1Min,
      msg.sender
    );

    (uint256 added0, uint256 added1) = IV3DexAdapter(ADAPTER).amountsForLiquidity(liquidityAdded, fairSqrtPriceX96);
    uint256 addedValue = _amountsValueUsd(added0, added1);
    if (supplyBefore == 0) {
      uint256 assetPrice = IOracle(resilientOracle).peek(asset()); // 8 decimals
      if (assetPrice > 0) shares = (addedValue * (10 ** uint256(accountingAssetDecimals))) / assetPrice;
    } else {
      shares = (addedValue * supplyBefore) / totalValueBefore;
    }
    if (shares == 0) revert ZeroShares();

    _mint(address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);

    emit Deposit(onBehalf, amount0Used, amount1Used, shares, marketParams.id());
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

    MOOLAH.withdrawCollateral(marketParams, shares, onBehalf, address(this));
    _afterCollateralChange(marketParams.id(), onBehalf);

    IV3DexAdapter(ADAPTER).collectAndCompound();

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

    _transfer(msg.sender, address(this), shares);
    _approve(address(this), address(MOOLAH), shares);
    MOOLAH.supplyCollateral(marketParams, shares, onBehalf, "");

    _afterCollateralChange(marketParams.id(), onBehalf);
    emit SharesSupplied(msg.sender, onBehalf, shares, marketParams.id());
  }

  /// @inheritdoc IV3Provider
  /// @dev Liquidation-critical path: no protocol value floor — caller's minAmount0/1 is the only
  ///      guard (a hard floor here would brick atomic liquidation; see finding C4).
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
    if (shares == 0) revert ZeroShares();
    if (receiver == address(0)) revert ZeroAddress();
    if (balanceOf(msg.sender) < shares) revert InsufficientShares();

    IV3DexAdapter(ADAPTER).collectAndCompound();

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

  /// @notice Simulate a redemption of `shares` at the current pool price (for tight minAmount0/1).
  function previewRedeemUnderlying(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
    return IV3DexAdapter(ADAPTER).previewRemoveLiquidity(shares, totalSupply());
  }

  /// @notice Simulate a deposit at the current pool price (for tight amount0Min/amount1Min).
  function previewDepositAmounts(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    return IV3DexAdapter(ADAPTER).previewAddLiquidity(amount0Desired, amount1Desired);
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
    return (amount0 * price0) / (10 ** DECIMALS0) + (amount1 * price1) / (10 ** DECIMALS1);
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

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20, IERC4626, ERC20Upgradeable, ERC4626Upgradeable, Math, SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { WAD } from "moolah/libraries/MathLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { ConstantsLib } from "./libraries/ConstantsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";

import { ISlisBnbProvider } from "../provider/interfaces/IProvider.sol";
import { IStakeManager } from "../provider/interfaces/IStakeManager.sol";
import { ISlisBNBxMinter } from "../utils/interfaces/ISlisBNBx.sol";
import { ICollateralYieldVault } from "./interfaces/ICollateralYieldVault.sol";

/// @title CollateralYieldVault
/// @author Lista DAO
/// @notice ERC4626 vault (asset = slisBNB). Deposited slisBNB is supplied as Moolah collateral (no borrow) via
///         SlisBNBProvider; the minted slisBNBx is 100% delegated to a MANAGER-set MPC (`delegateTarget`)
///         that participates in launchpool. Launchpool BNB rewards are injected back through `increaseVaultAssets`
///         (BOT-only) which stakes BNB->slisBNB, supplies it, and raises the share price. Performance fee follows the
///         MoolahVault model (fee-share dilution, high-water `lastTotalAssets`); `fee` is 0 at launch.
///         The vault is client-agnostic: per-deployment branding lives only in the token name/symbol.
contract CollateralYieldVault is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  PausableUpgradeable,
  ERC4626Upgradeable,
  ERC20PermitUpgradeable,
  ICollateralYieldVault
{
  using Math for uint256;
  using UtilsLib for uint256;
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;
  using MarketParamsLib for MarketParams;

  /* IMMUTABLES */

  /// @notice slisBNB, the vault asset, read from the provider (`PROVIDER.TOKEN()`).
  address public immutable SLIS_BNB;
  /// @notice Lista StakeManager (BNB -> slisBNB), read from the provider at construction.
  IStakeManager public immutable STAKE_MANAGER;
  /// @notice SlisBNBProvider that holds the Moolah collateral position on behalf of this vault.
  ISlisBnbProvider public immutable PROVIDER;
  /// @notice Moolah lending market contract, read from the provider at construction.
  IMoolah public immutable MOOLAH;

  /* ROLES */

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT"); // held by RewardHarvester

  /* STORAGE */

  /// @notice The Moolah market params whose collateralToken == slisBNB (no borrow performed).
  MarketParams public marketParams; //slisBNB/BNB market

  /// @notice Current delegate target (MPC participating in launchpool); MANAGER-set, must be non-zero.
  address public delegateTarget;

  /// @notice User whitelist; if non-empty, only listed addresses may deposit/hold shares.
  EnumerableSet.AddressSet private userWhiteList;

  /// @notice Performance fee (WAD); 0 at launch. fee <= MAX_FEE.
  uint96 public fee;
  /// @notice Recipient of fee shares.
  address public feeRecipient;
  /// @notice High-water snapshot of total assets for fee accrual.
  uint256 public lastTotalAssets;

  /* EVENTS */

  event SetFee(address indexed caller, uint256 fee);
  event SetFeeRecipient(address indexed feeRecipient);
  event SetWhiteList(address indexed account, bool enabled);
  event SetDelegateTarget(address indexed target);
  event IncreaseVaultAssets(address indexed caller, uint256 bnbIn, uint256 slisDelta);
  event UpdateLastTotalAssets(uint256 lastTotalAssets);
  event AccrueInterest(uint256 newTotalAssets, uint256 feeShares);
  event Swept(address indexed to, uint256 amount);
  event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

  /* ERRORS */

  error ZeroAmount();
  error SharesOutstanding();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _provider) {
    if (_provider == address(0)) revert ErrorsLib.ZeroAddress();
    _disableInitializers();
    PROVIDER = ISlisBnbProvider(_provider);
    // slisBNB (asset) and StakeManager are read from the provider's immutables;
    // slisBNBxMinter is read dynamically at use (the provider may re-set it).
    SLIS_BNB = PROVIDER.TOKEN();
    STAKE_MANAGER = IStakeManager(PROVIDER.STAKE_MANAGER());
    MOOLAH = IMoolah(PROVIDER.MOOLAH());
    // asset is always slisBNB (18 decimals) => ERC4626 decimals offset is 0 (the inherited default).
  }

  /// @param admin DEFAULT_ADMIN_ROLE (timelock/governance).
  /// @param manager MANAGER role.
  /// @param pauser PAUSER role.
  /// @param _marketParams Moolah market with collateralToken == slisBNB.
  /// @param _name vault token name.
  /// @param _symbol vault token symbol.
  function initialize(
    address admin,
    address manager,
    address pauser,
    MarketParams calldata _marketParams,
    string memory _name,
    string memory _symbol
  ) external initializer {
    if (admin == address(0) || manager == address(0) || pauser == address(0)) revert ErrorsLib.ZeroAddress();
    if (_marketParams.collateralToken != SLIS_BNB) revert ErrorsLib.TokenMismatch();

    __AccessControl_init();
    __ReentrancyGuard_init();
    __Pausable_init();
    __ERC4626_init(IERC20(SLIS_BNB));
    __ERC20_init(_name, _symbol);
    __ERC20Permit_init(_name);

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);

    marketParams = _marketParams;
    // fee defaults to 0; feeRecipient unset until governance enables fee.

    // Allow the provider to pull slisBNB on supply.
    IERC20(SLIS_BNB).forceApprove(address(PROVIDER), type(uint256).max);
  }

  /* DEPOSIT (slisBNB) */

  /// @inheritdoc IERC4626
  function deposit(
    uint256 assets,
    address receiver
  ) public override nonReentrant whenNotPaused returns (uint256 shares) {
    _checkWhiteList(receiver);
    uint256 newTotalAssets = _accrueFee();
    lastTotalAssets = newTotalAssets;
    shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);
    if (shares == 0) revert ZeroAmount();
    _deposit(_msgSender(), receiver, assets, shares);
  }

  /// @inheritdoc IERC4626
  function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256 assets) {
    _checkWhiteList(receiver);
    uint256 newTotalAssets = _accrueFee();
    lastTotalAssets = newTotalAssets;
    assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Ceil);
    _deposit(_msgSender(), receiver, assets, shares);
  }

  /// @notice Convenience entry: deposit native BNB; the vault stakes it to slisBNB then supplies it.
  function depositBNB(address receiver) external payable nonReentrant whenNotPaused returns (uint256 shares) {
    _checkWhiteList(receiver);
    if (msg.value == 0) revert ZeroAmount();

    uint256 newTotalAssets = _accrueFee();
    lastTotalAssets = newTotalAssets;

    uint256 balBefore = IERC20(SLIS_BNB).balanceOf(address(this));
    STAKE_MANAGER.deposit{ value: msg.value }();
    uint256 assets = IERC20(SLIS_BNB).balanceOf(address(this)) - balBefore;

    shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);
    if (shares == 0) revert ZeroAmount();

    _mint(receiver, shares);
    emit Deposit(_msgSender(), receiver, assets, shares);

    PROVIDER.supplyCollateral(marketParams, assets, address(this), "");
    _updateLastTotalAssets(newTotalAssets + assets);
  }

  /* REDEEM / WITHDRAW (slisBNB) */

  /// @inheritdoc IERC4626
  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override nonReentrant returns (uint256 shares) {
    uint256 newTotalAssets = _accrueFee();
    shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);
    _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));
    _withdraw(_msgSender(), receiver, owner, assets, shares);
  }

  /// @inheritdoc IERC4626
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override nonReentrant returns (uint256 assets) {
    uint256 newTotalAssets = _accrueFee();
    assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);
    _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));
    _withdraw(_msgSender(), receiver, owner, assets, shares);
  }

  /* COMPOUND (BOT == RewardHarvester) */

  /// @notice Inject launchpool reward BNB (`msg.value`): stake to slisBNB, supply to the position, then accrue fee on
  ///         the increment. Mints no user shares => share price rises. Initial `fee` = 0 => increment fully accrues
  ///         to holders. Only the slisBNB minted from this call's `msg.value` is compounded (measured as a balance
  ///         delta), so any unrelated slisBNB sitting in the vault is never swept into the position here.
  function increaseVaultAssets() external payable override onlyRole(BOT) nonReentrant whenNotPaused {
    if (msg.value == 0) revert ZeroAmount();

    uint256 balBefore = IERC20(SLIS_BNB).balanceOf(address(this));
    STAKE_MANAGER.deposit{ value: msg.value }();
    uint256 slisDelta = IERC20(SLIS_BNB).balanceOf(address(this)) - balBefore;

    PROVIDER.supplyCollateral(marketParams, slisDelta, address(this), "");
    // Inject first, accrue after: the increment is booked as interest and charged `fee` (0 at launch).
    _updateLastTotalAssets(_accrueFee());

    emit IncreaseVaultAssets(_msgSender(), msg.value, slisDelta);
  }

  /// @notice Permissionlessly crystallize accrued performance fee into fee shares (no-op while `fee == 0`).
  function accrueFee() external nonReentrant {
    _updateLastTotalAssets(_accrueFee());
  }

  /* VIEWS */

  /// @inheritdoc IERC4626
  /// @dev NAV = the vault's slisBNB collateral in *this exact Moolah market*, read live from Moolah. Reading the
  ///      per-market position (not the provider's cross-market `userTotalDeposit`) ensures NAV only ever reflects
  ///      collateral that the vault can actually withdraw from this market, so slisBNB the vault supplies to any
  ///      other market cannot inflate the share price. Note: an external party can still raise this by calling
  ///      `SlisBNBProvider.supplyCollateral(onBehalf=vault)` against this market (a donation that benefits holders).
  function totalAssets() public view override returns (uint256) {
    return MOOLAH.position(marketParams.id(), address(this)).collateral;
  }

  /// @dev Mirrors the deposit gate (`whenNotPaused` + `_checkWhiteList`): a deposit reverts unless BOTH the caller
  ///      and the receiver are whitelisted, so reflect the `_msgSender()` whitelist here too.
  function maxDeposit(address receiver) public view override returns (uint256) {
    if (paused() || !isWhiteList(_msgSender()) || !isWhiteList(receiver)) return 0;
    return type(uint256).max;
  }

  /// @dev See {maxDeposit}: reflects both the caller and receiver whitelist so it cannot signal a mint that reverts.
  function maxMint(address receiver) public view override returns (uint256) {
    if (paused() || !isWhiteList(_msgSender()) || !isWhiteList(receiver)) return 0;
    return type(uint256).max;
  }

  /// @notice If the whitelist is empty it is treated as open (everyone allowed).
  function isWhiteList(address account) public view returns (bool) {
    return userWhiteList.length() == 0 || userWhiteList.contains(account);
  }

  function getWhiteList() external view returns (address[] memory) {
    return userWhiteList.values();
  }

  /* MANAGER: FEE */

  function setFee(uint256 newFee) external onlyRole(MANAGER) {
    if (newFee == fee) revert ErrorsLib.AlreadySet();
    if (newFee > ConstantsLib.MAX_FEE) revert ErrorsLib.MaxFeeExceeded();
    if (newFee != 0 && feeRecipient == address(0)) revert ErrorsLib.ZeroFeeRecipient();

    _updateLastTotalAssets(_accrueFee());
    fee = uint96(newFee);
    emit SetFee(_msgSender(), newFee);
  }

  function setFeeRecipient(address newFeeRecipient) external onlyRole(MANAGER) {
    if (newFeeRecipient == feeRecipient) revert ErrorsLib.AlreadySet();
    if (newFeeRecipient == address(0) && fee != 0) revert ErrorsLib.ZeroFeeRecipient();

    _updateLastTotalAssets(_accrueFee());
    feeRecipient = newFeeRecipient;
    emit SetFeeRecipient(newFeeRecipient);
  }

  /* MANAGER: USER WHITELIST */

  function setWhiteList(address account, bool enabled) external onlyRole(MANAGER) {
    if (account == address(0)) revert ErrorsLib.ZeroAddress();
    if (enabled) {
      if (!userWhiteList.add(account)) revert ErrorsLib.AlreadySet();
    } else {
      if (!userWhiteList.remove(account)) revert ErrorsLib.NotSet();
    }
    emit SetWhiteList(account, enabled);
  }

  /* MANAGER: DELEGATE TARGET (MPC) */

  function setDelegateTarget(address target) external onlyRole(MANAGER) {
    if (target == address(0)) revert ErrorsLib.ZeroAddress();
    delegateTarget = target;
    // Redirect 100% of the vault's slisBNBx to the chosen MPC (minter read from the provider).
    ISlisBNBxMinter(PROVIDER.slisBNBxMinter()).delegateAllTo(target);
    emit SetDelegateTarget(target);
  }

  /* MANAGER: SWEEP */

  /// @notice Recover residual collateral left in the position once every share has been redeemed
  ///         (last-redeemer rounding dust), and reset the vault to a clean empty state.
  /// @dev Gated on `totalSupply() == 0`: with no shares outstanding nothing backs user value, so this can never
  ///      touch share-backed funds. A deploy-time dead seed deposit keeps supply > 0 and prevents this state.
  function sweep(address to) external onlyRole(MANAGER) nonReentrant returns (uint256 amount) {
    if (totalSupply() != 0) revert SharesOutstanding();
    if (to == address(0)) revert ErrorsLib.ZeroAddress();
    amount = totalAssets();
    if (amount > 0) {
      PROVIDER.withdrawCollateral(marketParams, amount, address(this), to);
      _updateLastTotalAssets(0);
    }
    emit Swept(to, amount);
  }

  /// @notice Recover stray tokens / native BNB held by the vault (e.g. directly-donated slisBNB that
  ///         `increaseVaultAssets` does not fold in). Does NOT touch the Moolah collateral position (which backs
  ///         shares and is custodied by the provider/Moolah), so `totalAssets` is unaffected. MANAGER-only.
  function emergencyWithdraw(uint256 amount, address token) external onlyRole(MANAGER) nonReentrant {
    if (token == address(0)) {
      (bool ok, ) = payable(_msgSender()).call{ value: amount }("");
      require(ok, "BNB transfer failed");
    } else {
      IERC20(token).safeTransfer(_msgSender(), amount);
    }
    emit EmergencyWithdraw(token, _msgSender(), amount);
  }

  /* PAUSER */

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /* INTERNAL: ERC4626 hooks */

  function _checkWhiteList(address receiver) private view {
    require(isWhiteList(_msgSender()) && isWhiteList(receiver), ErrorsLib.NotWhiteList());
  }

  /// @dev super._deposit pulls slisBNB from caller and mints shares; then supply it as collateral.
  function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    super._deposit(caller, receiver, assets, shares);
    PROVIDER.supplyCollateral(marketParams, assets, address(this), "");
    _updateLastTotalAssets(lastTotalAssets + assets);
  }

  /// @dev Pull slisBNB out of the Moolah position into the vault, then let ERC4626 handle the
  ///      allowance spend, share burn, asset transfer to `receiver`, and Withdraw event.
  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal override {
    PROVIDER.withdrawCollateral(marketParams, assets, address(this), address(this));
    super._withdraw(caller, receiver, owner, assets, shares);
  }

  /// @dev Restrict share transfers to whitelisted holders (mint/burn always allowed).
  function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {
      require(isWhiteList(from) && isWhiteList(to), ErrorsLib.NotWhiteList());
    }
    super._update(from, to, value);
  }

  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
    return ERC4626Upgradeable.decimals();
  }

  /* INTERNAL: conversions with fee */

  function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
    (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
    return _convertToSharesWithTotals(assets, totalSupply() + feeShares, newTotalAssets, rounding);
  }

  function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
    (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
    return _convertToAssetsWithTotals(shares, totalSupply() + feeShares, newTotalAssets, rounding);
  }

  function _convertToSharesWithTotals(
    uint256 assets,
    uint256 newTotalSupply,
    uint256 newTotalAssets,
    Math.Rounding rounding
  ) internal view returns (uint256) {
    return assets.mulDiv(newTotalSupply + 1, newTotalAssets + 1, rounding);
  }

  function _convertToAssetsWithTotals(
    uint256 shares,
    uint256 newTotalSupply,
    uint256 newTotalAssets,
    Math.Rounding rounding
  ) internal view returns (uint256) {
    return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 1, rounding);
  }

  /* INTERNAL: fee */

  function _updateLastTotalAssets(uint256 updatedTotalAssets) internal {
    lastTotalAssets = updatedTotalAssets;
    emit UpdateLastTotalAssets(updatedTotalAssets);
  }

  function _accrueFee() internal returns (uint256 newTotalAssets) {
    uint256 feeShares;
    (feeShares, newTotalAssets) = _accruedFeeShares();
    if (feeShares != 0) _mint(feeRecipient, feeShares);
    emit AccrueInterest(newTotalAssets, feeShares);
  }

  function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalAssets) {
    newTotalAssets = totalAssets();
    uint256 totalInterest = newTotalAssets.zeroFloorSub(lastTotalAssets);
    if (totalInterest != 0 && fee != 0) {
      uint256 feeAssets = totalInterest.mulDiv(fee, WAD);
      feeShares = _convertToSharesWithTotals(feeAssets, totalSupply(), newTotalAssets - feeAssets, Math.Rounding.Floor);
    }
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

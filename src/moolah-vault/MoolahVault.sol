// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MulticallUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20, IERC4626, ERC20Upgradeable, ERC4626Upgradeable, Math, SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { MarketConfig, PendingUint192, PendingAddress, MarketAllocation, IMoolahVaultBase, IMoolahVaultStaticTyping } from "./interfaces/IMoolahVault.sol";
import { Id, MarketParams, Market, IMoolah } from "moolah/interfaces/IMoolah.sol";

import { PendingUint192, PendingAddress, PendingLib } from "./libraries/PendingLib.sol";
import { ConstantsLib } from "./libraries/ConstantsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";
import { WAD } from "moolah/libraries/MathLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";

/// @title MoolahVault
/// @author Lista DAO
/// @notice ERC4626 compliant vault allowing users to deposit assets to Moolah.
contract MoolahVault is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ERC4626Upgradeable,
  ERC20PermitUpgradeable,
  MulticallUpgradeable,
  IMoolahVaultStaticTyping
{
  using Math for uint256;
  using UtilsLib for uint256;
  using SafeCast for uint256;
  using SafeERC20 for IERC20;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;
  using MoolahBalancesLib for IMoolah;
  using PendingLib for MarketConfig;
  using PendingLib for PendingUint192;
  using PendingLib for PendingAddress;

  /* IMMUTABLES */

  /// @inheritdoc IMoolahVaultBase
  IMoolah public immutable MOOLAH;

  /// @notice OpenZeppelin decimals offset used by the ERC4626 implementation.
  /// @dev Calculated to be max(0, 18 - underlyingDecimals) at construction, so the initial conversion rate maximizes
  /// precision between shares and assets.
  uint8 public immutable DECIMALS_OFFSET;

  /* STORAGE */

  /// @inheritdoc IMoolahVaultStaticTyping
  mapping(Id => MarketConfig) public config;

  /// @inheritdoc IMoolahVaultBase
  uint96 public fee;

  /// @inheritdoc IMoolahVaultBase
  address public feeRecipient;

  /// @inheritdoc IMoolahVaultBase
  address public skimRecipient;

  /// @inheritdoc IMoolahVaultBase
  Id[] public supplyQueue;

  /// @inheritdoc IMoolahVaultBase
  Id[] public withdrawQueue;

  /// @inheritdoc IMoolahVaultBase
  uint256 public lastTotalAssets;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role
  bytes32 public constant GUARDIAN = keccak256("GUARDIAN"); // manager role

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  /// @param _asset The address of the underlying asset.
  constructor(address moolah, address _asset) {
    if (moolah == address(0)) revert ErrorsLib.ZeroAddress();
    _disableInitializers();
    MOOLAH = IMoolah(moolah);
    DECIMALS_OFFSET = uint8(uint256(18).zeroFloorSub(IERC20Metadata(_asset).decimals()));
  }

  /// @dev Initializes the contract.
  /// @param admin The new admin of the contract.
  /// @param manager The new manager of the contract.
  /// @param _asset The address of the underlying asset.
  /// @param _name The name of the vault.
  /// @param _symbol The symbol of the vault.
  function initialize(
    address admin,
    address manager,
    address _asset,
    string memory _name,
    string memory _symbol
  ) public initializer {
    if (admin == address(0)) revert ErrorsLib.ZeroAddress();
    if (manager == address(0)) revert ErrorsLib.ZeroAddress();

    __ERC4626_init(IERC20(_asset));
    __ERC20_init(_name, _symbol);
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _setRoleAdmin(CURATOR, MANAGER);
    _setRoleAdmin(ALLOCATOR, MANAGER);
    _setRoleAdmin(GUARDIAN, MANAGER);

    IERC20(_asset).forceApprove(address(MOOLAH), type(uint256).max);
  }

  /* ONLY MANAGER FUNCTIONS */

  /// @inheritdoc IMoolahVaultBase
  function setSkimRecipient(address newSkimRecipient) external onlyRole(MANAGER) {
    if (newSkimRecipient == skimRecipient) revert ErrorsLib.AlreadySet();

    skimRecipient = newSkimRecipient;

    emit EventsLib.SetSkimRecipient(newSkimRecipient);
  }

  /// @inheritdoc IMoolahVaultBase
  function setFee(uint256 newFee) external onlyRole(MANAGER) {
    if (newFee == fee) revert ErrorsLib.AlreadySet();
    if (newFee > ConstantsLib.MAX_FEE) revert ErrorsLib.MaxFeeExceeded();
    if (newFee != 0 && feeRecipient == address(0)) revert ErrorsLib.ZeroFeeRecipient();

    // Accrue fee using the previous fee set before changing it.
    _updateLastTotalAssets(_accrueFee());

    // Safe "unchecked" cast because newFee <= MAX_FEE.
    fee = uint96(newFee);

    emit EventsLib.SetFee(_msgSender(), fee);
  }

  /// @inheritdoc IMoolahVaultBase
  function setFeeRecipient(address newFeeRecipient) external onlyRole(MANAGER) {
    if (newFeeRecipient == feeRecipient) revert ErrorsLib.AlreadySet();
    if (newFeeRecipient == address(0) && fee != 0) revert ErrorsLib.ZeroFeeRecipient();

    // Accrue fee to the previous fee recipient set before changing it.
    _updateLastTotalAssets(_accrueFee());

    feeRecipient = newFeeRecipient;

    emit EventsLib.SetFeeRecipient(newFeeRecipient);
  }

  /* ONLY CURATOR FUNCTIONS */

  /// @inheritdoc IMoolahVaultBase
  function setCap(MarketParams memory marketParams, uint256 newSupplyCap) external onlyRole(CURATOR) {
    Id id = marketParams.id();
    if (marketParams.loanToken != asset()) revert ErrorsLib.InconsistentAsset(id);
    if (MOOLAH.market(id).lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
    if (config[id].removableAt != 0) revert ErrorsLib.PendingRemoval();
    uint256 supplyCap = config[id].cap;
    if (newSupplyCap == supplyCap) revert ErrorsLib.AlreadySet();

    _setCap(marketParams, id, newSupplyCap.toUint184());
  }

  /// @inheritdoc IMoolahVaultBase
  function setMarketRemoval(MarketParams memory marketParams) external onlyRole(CURATOR) {
    Id id = marketParams.id();
    if (config[id].removableAt != 0) revert ErrorsLib.AlreadyPending();
    if (config[id].cap != 0) revert ErrorsLib.NonZeroCap();
    if (!config[id].enabled) revert ErrorsLib.MarketNotEnabled(id);

    config[id].removableAt = uint64(block.timestamp);
  }

  /* ONLY ALLOCATOR FUNCTIONS */

  /// @inheritdoc IMoolahVaultBase
  function setSupplyQueue(Id[] calldata newSupplyQueue) external onlyRole(ALLOCATOR) {
    uint256 length = newSupplyQueue.length;

    if (length > ConstantsLib.MAX_QUEUE_LENGTH) revert ErrorsLib.MaxQueueLengthExceeded();

    for (uint256 i; i < length; ++i) {
      if (config[newSupplyQueue[i]].cap == 0) revert ErrorsLib.UnauthorizedMarket(newSupplyQueue[i]);
    }

    supplyQueue = newSupplyQueue;

    emit EventsLib.SetSupplyQueue(_msgSender(), newSupplyQueue);
  }

  /// @inheritdoc IMoolahVaultBase
  function updateWithdrawQueue(uint256[] calldata indexes) external onlyRole(ALLOCATOR) {
    uint256 newLength = indexes.length;
    uint256 currLength = withdrawQueue.length;

    bool[] memory seen = new bool[](currLength);
    Id[] memory newWithdrawQueue = new Id[](newLength);

    for (uint256 i; i < newLength; ++i) {
      uint256 prevIndex = indexes[i];

      // If prevIndex >= currLength, it will revert with native "Index out of bounds".
      Id id = withdrawQueue[prevIndex];
      if (seen[prevIndex]) revert ErrorsLib.DuplicateMarket(id);
      seen[prevIndex] = true;

      newWithdrawQueue[i] = id;
    }

    for (uint256 i; i < currLength; ++i) {
      if (!seen[i]) {
        Id id = withdrawQueue[i];

        if (config[id].cap != 0) revert ErrorsLib.InvalidMarketRemovalNonZeroCap(id);

        if (MOOLAH.position(id, address(this)).supplyShares != 0) {
          if (config[id].removableAt == 0) revert ErrorsLib.InvalidMarketRemovalNonZeroSupply(id);

          if (block.timestamp < config[id].removableAt) {
            revert ErrorsLib.InvalidMarketRemovalTimelockNotElapsed(id);
          }
        }

        delete config[id];
      }
    }

    withdrawQueue = newWithdrawQueue;

    emit EventsLib.SetWithdrawQueue(_msgSender(), newWithdrawQueue);
  }

  /// @inheritdoc IMoolahVaultBase
  function reallocate(MarketAllocation[] calldata allocations) external onlyRole(ALLOCATOR) {
    uint256 totalSupplied;
    uint256 totalWithdrawn;
    for (uint256 i; i < allocations.length; ++i) {
      MarketAllocation memory allocation = allocations[i];
      Id id = allocation.marketParams.id();

      (uint256 supplyAssets, uint256 supplyShares, ) = _accruedSupplyBalance(allocation.marketParams, id);
      uint256 withdrawn = supplyAssets.zeroFloorSub(allocation.assets);

      if (withdrawn > 0) {
        if (!config[id].enabled) revert ErrorsLib.MarketNotEnabled(id);

        // Guarantees that unknown frontrunning donations can be withdrawn, in order to disable a market.
        uint256 shares;
        if (allocation.assets == 0) {
          shares = supplyShares;
          withdrawn = 0;
        }

        (uint256 withdrawnAssets, uint256 withdrawnShares) = MOOLAH.withdraw(
          allocation.marketParams,
          withdrawn,
          shares,
          address(this),
          address(this)
        );

        emit EventsLib.ReallocateWithdraw(_msgSender(), id, withdrawnAssets, withdrawnShares);

        totalWithdrawn += withdrawnAssets;
      } else {
        uint256 suppliedAssets = allocation.assets == type(uint256).max
          ? totalWithdrawn.zeroFloorSub(totalSupplied)
          : allocation.assets.zeroFloorSub(supplyAssets);

        if (suppliedAssets == 0) continue;

        uint256 supplyCap = config[id].cap;
        if (supplyCap == 0) revert ErrorsLib.UnauthorizedMarket(id);

        if (supplyAssets + suppliedAssets > supplyCap) revert ErrorsLib.SupplyCapExceeded(id);

        // The market's loan asset is guaranteed to be the vault's asset because it has a non-zero supply cap.
        (, uint256 suppliedShares) = MOOLAH.supply(allocation.marketParams, suppliedAssets, 0, address(this), hex"");

        emit EventsLib.ReallocateSupply(_msgSender(), id, suppliedAssets, suppliedShares);

        totalSupplied += suppliedAssets;
      }
    }

    if (totalWithdrawn != totalSupplied) revert ErrorsLib.InconsistentReallocation();
  }

  /* EXTERNAL */

  /// @inheritdoc IMoolahVaultBase
  function supplyQueueLength() external view returns (uint256) {
    return supplyQueue.length;
  }

  /// @inheritdoc IMoolahVaultBase
  function withdrawQueueLength() external view returns (uint256) {
    return withdrawQueue.length;
  }

  /// @inheritdoc IMoolahVaultBase
  function skim(address token) external {
    if (skimRecipient == address(0)) revert ErrorsLib.ZeroAddress();

    uint256 amount = IERC20(token).balanceOf(address(this));

    IERC20(token).safeTransfer(skimRecipient, amount);

    emit EventsLib.Skim(_msgSender(), token, amount);
  }

  /* ERC4626Upgradeable (PUBLIC) */

  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
    return ERC4626Upgradeable.decimals();
  }

  /// @inheritdoc IERC4626
  /// @dev Warning: May be higher than the actual max deposit due to duplicate markets in the supplyQueue.
  function maxDeposit(address) public view override returns (uint256) {
    return _maxDeposit();
  }

  /// @inheritdoc IERC4626
  /// @dev Warning: May be higher than the actual max mint due to duplicate markets in the supplyQueue.
  function maxMint(address) public view override returns (uint256) {
    uint256 suppliable = _maxDeposit();

    return _convertToShares(suppliable, Math.Rounding.Floor);
  }

  /// @inheritdoc IERC4626
  /// @dev Warning: May be lower than the actual amount of assets that can be withdrawn by `owner` due to conversion
  /// roundings between shares and assets.
  function maxWithdraw(address owner) public view override returns (uint256 assets) {
    (assets, , ) = _maxWithdraw(owner);
  }

  /// @inheritdoc IERC4626
  /// @dev Warning: May be lower than the actual amount of shares that can be redeemed by `owner` due to conversion
  /// roundings between shares and assets.
  function maxRedeem(address owner) public view override returns (uint256) {
    (uint256 assets, uint256 newTotalSupply, uint256 newTotalAssets) = _maxWithdraw(owner);

    return _convertToSharesWithTotals(assets, newTotalSupply, newTotalAssets, Math.Rounding.Floor);
  }

  /// @inheritdoc IERC4626
  function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
    uint256 newTotalAssets = _accrueFee();

    // Update `lastTotalAssets` to avoid an inconsistent state in a re-entrant context.
    // It is updated again in `_deposit`.
    lastTotalAssets = newTotalAssets;

    shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);

    _deposit(_msgSender(), receiver, assets, shares);
  }

  /// @inheritdoc IERC4626
  function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
    uint256 newTotalAssets = _accrueFee();

    // Update `lastTotalAssets` to avoid an inconsistent state in a re-entrant context.
    // It is updated again in `_deposit`.
    lastTotalAssets = newTotalAssets;

    assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

    _deposit(_msgSender(), receiver, assets, shares);
  }

  /// @inheritdoc IERC4626
  function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
    uint256 newTotalAssets = _accrueFee();

    // Do not call expensive `maxWithdraw` and optimistically withdraw assets.

    shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

    // `newTotalAssets - assets` may be a little off from `totalAssets()`.
    _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

    _withdraw(_msgSender(), receiver, owner, assets, shares);
  }

  /// @inheritdoc IERC4626
  function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
    uint256 newTotalAssets = _accrueFee();

    // Do not call expensive `maxRedeem` and optimistically redeem shares.

    assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

    // `newTotalAssets - assets` may be a little off from `totalAssets()`.
    _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

    _withdraw(_msgSender(), receiver, owner, assets, shares);
  }

  /// @inheritdoc IERC4626
  function totalAssets() public view override returns (uint256 assets) {
    for (uint256 i; i < withdrawQueue.length; ++i) {
      assets += MOOLAH.expectedSupplyAssets(_marketParams(withdrawQueue[i]), address(this));
    }
  }

  /* ERC4626Upgradeable (INTERNAL) */

  /// @inheritdoc ERC4626Upgradeable
  function _decimalsOffset() internal view override returns (uint8) {
    return DECIMALS_OFFSET;
  }

  /// @dev Returns the maximum amount of asset (`assets`) that the `owner` can withdraw from the vault, as well as the
  /// new vault's total supply (`newTotalSupply`) and total assets (`newTotalAssets`).
  function _maxWithdraw(
    address owner
  ) internal view returns (uint256 assets, uint256 newTotalSupply, uint256 newTotalAssets) {
    uint256 feeShares;
    (feeShares, newTotalAssets) = _accruedFeeShares();
    newTotalSupply = totalSupply() + feeShares;

    assets = _convertToAssetsWithTotals(balanceOf(owner), newTotalSupply, newTotalAssets, Math.Rounding.Floor);
    assets -= _simulateWithdrawMoolah(assets);
  }

  /// @dev Returns the maximum amount of assets that the vault can supply on Moolah.
  function _maxDeposit() internal view returns (uint256 totalSuppliable) {
    for (uint256 i; i < supplyQueue.length; ++i) {
      Id id = supplyQueue[i];

      uint256 supplyCap = config[id].cap;
      if (supplyCap == 0) continue;

      uint256 supplyShares = MOOLAH.position(id, address(this)).supplyShares;
      (uint256 totalSupplyAssets, uint256 totalSupplyShares, , ) = MOOLAH.expectedMarketBalances(_marketParams(id));
      // `supplyAssets` needs to be rounded up for `totalSuppliable` to be rounded down.
      uint256 supplyAssets = supplyShares.toAssetsUp(totalSupplyAssets, totalSupplyShares);

      totalSuppliable += supplyCap.zeroFloorSub(supplyAssets);
    }
  }

  /// @inheritdoc ERC4626Upgradeable
  /// @dev The accrual of performance fees is taken into account in the conversion.
  function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
    (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();

    return _convertToSharesWithTotals(assets, totalSupply() + feeShares, newTotalAssets, rounding);
  }

  /// @inheritdoc ERC4626Upgradeable
  /// @dev The accrual of performance fees is taken into account in the conversion.
  function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
    (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();

    return _convertToAssetsWithTotals(shares, totalSupply() + feeShares, newTotalAssets, rounding);
  }

  /// @dev Returns the amount of shares that the vault would exchange for the amount of `assets` provided.
  /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
  function _convertToSharesWithTotals(
    uint256 assets,
    uint256 newTotalSupply,
    uint256 newTotalAssets,
    Math.Rounding rounding
  ) internal view returns (uint256) {
    return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, rounding);
  }

  /// @dev Returns the amount of assets that the vault would exchange for the amount of `shares` provided.
  /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
  function _convertToAssetsWithTotals(
    uint256 shares,
    uint256 newTotalSupply,
    uint256 newTotalAssets,
    Math.Rounding rounding
  ) internal view returns (uint256) {
    return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), rounding);
  }

  /// @inheritdoc ERC4626Upgradeable
  /// @dev Used in mint or deposit to deposit the underlying asset to Moolah markets.
  function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    super._deposit(caller, receiver, assets, shares);

    _supplyMoolah(assets);

    // `lastTotalAssets + assets` may be a little off from `totalAssets()`.
    _updateLastTotalAssets(lastTotalAssets + assets);
  }

  /// @inheritdoc ERC4626Upgradeable
  /// @dev Used in redeem or withdraw to withdraw the underlying asset from Moolah markets.
  /// @dev Depending on 3 cases, reverts when withdrawing "too much" with:
  /// 1. NotEnoughLiquidity when withdrawing more than available liquidity.
  /// 2. ERC20InsufficientAllowance when withdrawing more than `caller`'s allowance.
  /// 3. ERC20InsufficientBalance when withdrawing more than `owner`'s balance.
  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal override {
    _withdrawMoolah(assets);

    super._withdraw(caller, receiver, owner, assets, shares);
  }

  /* INTERNAL */

  /// @dev Returns the market params of the market defined by `id`.
  function _marketParams(Id id) internal view returns (MarketParams memory) {
    return MOOLAH.idToMarketParams(id);
  }

  /// @dev Accrues interest on Moolah and returns the vault's assets & corresponding shares supplied on the
  /// market defined by `marketParams`, as well as the market's state.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function _accruedSupplyBalance(
    MarketParams memory marketParams,
    Id id
  ) internal returns (uint256 assets, uint256 shares, Market memory market) {
    MOOLAH.accrueInterest(marketParams);

    market = MOOLAH.market(id);
    shares = MOOLAH.position(id, address(this)).supplyShares;
    assets = shares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
  }

  /// @dev Sets the cap of the market defined by `id` to `supplyCap`.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function _setCap(MarketParams memory marketParams, Id id, uint184 supplyCap) internal {
    MarketConfig storage marketConfig = config[id];

    if (supplyCap > 0) {
      if (!marketConfig.enabled) {
        withdrawQueue.push(id);

        if (withdrawQueue.length > ConstantsLib.MAX_QUEUE_LENGTH) revert ErrorsLib.MaxQueueLengthExceeded();

        marketConfig.enabled = true;

        // Take into account assets of the new market without applying a fee.
        _updateLastTotalAssets(lastTotalAssets + MOOLAH.expectedSupplyAssets(marketParams, address(this)));

        emit EventsLib.SetWithdrawQueue(msg.sender, withdrawQueue);
      }

      marketConfig.removableAt = 0;
    }

    marketConfig.cap = supplyCap;

    emit EventsLib.SetCap(_msgSender(), id, supplyCap);
  }

  /* LIQUIDITY ALLOCATION */

  /// @dev Supplies `assets` to Moolah.
  function _supplyMoolah(uint256 assets) internal {
    for (uint256 i; i < supplyQueue.length; ++i) {
      Id id = supplyQueue[i];

      uint256 supplyCap = config[id].cap;
      if (supplyCap == 0) continue;

      MarketParams memory marketParams = _marketParams(id);

      MOOLAH.accrueInterest(marketParams);

      Market memory market = MOOLAH.market(id);
      uint256 supplyShares = MOOLAH.position(id, address(this)).supplyShares;
      // `supplyAssets` needs to be rounded up for `toSupply` to be rounded down.
      uint256 supplyAssets = supplyShares.toAssetsUp(market.totalSupplyAssets, market.totalSupplyShares);

      uint256 toSupply = UtilsLib.min(supplyCap.zeroFloorSub(supplyAssets), assets);

      if (toSupply > 0) {
        // Using try/catch to skip markets that revert.
        try MOOLAH.supply(marketParams, toSupply, 0, address(this), hex"") {
          assets -= toSupply;
        } catch {}
      }

      if (assets == 0) return;
    }

    if (assets != 0) revert ErrorsLib.AllCapsReached();
  }

  /// @dev Withdraws `assets` from Moolah.
  function _withdrawMoolah(uint256 assets) internal {
    for (uint256 i; i < withdrawQueue.length; ++i) {
      Id id = withdrawQueue[i];
      MarketParams memory marketParams = _marketParams(id);
      (uint256 supplyAssets, , Market memory market) = _accruedSupplyBalance(marketParams, id);

      uint256 toWithdraw = UtilsLib.min(
        _withdrawable(marketParams, market.totalSupplyAssets, market.totalBorrowAssets, supplyAssets),
        assets
      );

      if (toWithdraw > 0) {
        // Using try/catch to skip markets that revert.
        try MOOLAH.withdraw(marketParams, toWithdraw, 0, address(this), address(this)) {
          assets -= toWithdraw;
        } catch {}
      }

      if (assets == 0) return;
    }

    if (assets != 0) revert ErrorsLib.NotEnoughLiquidity();
  }

  /// @dev Simulates a withdraw of `assets` from Moolah.
  /// @return The remaining assets to be withdrawn.
  function _simulateWithdrawMoolah(uint256 assets) internal view returns (uint256) {
    for (uint256 i; i < withdrawQueue.length; ++i) {
      Id id = withdrawQueue[i];
      MarketParams memory marketParams = _marketParams(id);

      uint256 supplyShares = MOOLAH.position(id, address(this)).supplyShares;
      (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, ) = MOOLAH
        .expectedMarketBalances(marketParams);

      // The vault withdrawing from Moolah cannot fail because:
      // 1. oracle.price() is never called (the vault doesn't borrow)
      // 2. the amount is capped to the liquidity available on Moolah
      // 3. virtually accruing interest didn't fail
      assets = assets.zeroFloorSub(
        _withdrawable(
          marketParams,
          totalSupplyAssets,
          totalBorrowAssets,
          supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares)
        )
      );

      if (assets == 0) break;
    }

    return assets;
  }

  /// @dev Returns the withdrawable amount of assets from the market defined by `marketParams`, given the market's
  /// total supply and borrow assets and the vault's assets supplied.
  function _withdrawable(
    MarketParams memory marketParams,
    uint256 totalSupplyAssets,
    uint256 totalBorrowAssets,
    uint256 supplyAssets
  ) internal view returns (uint256) {
    // Inside a flashloan callback, liquidity on Moolah may be limited to the singleton's balance.
    uint256 availableLiquidity = UtilsLib.min(
      totalSupplyAssets - totalBorrowAssets,
      ERC20Upgradeable(marketParams.loanToken).balanceOf(address(MOOLAH))
    );

    return UtilsLib.min(supplyAssets, availableLiquidity);
  }

  /* FEE MANAGEMENT */

  /// @dev Updates `lastTotalAssets` to `updatedTotalAssets`.
  function _updateLastTotalAssets(uint256 updatedTotalAssets) internal {
    lastTotalAssets = updatedTotalAssets;

    emit EventsLib.UpdateLastTotalAssets(updatedTotalAssets);
  }

  /// @dev Accrues the fee and mints the fee shares to the fee recipient.
  /// @return newTotalAssets The vaults total assets after accruing the interest.
  function _accrueFee() internal returns (uint256 newTotalAssets) {
    uint256 feeShares;
    (feeShares, newTotalAssets) = _accruedFeeShares();

    if (feeShares != 0) _mint(feeRecipient, feeShares);

    emit EventsLib.AccrueInterest(newTotalAssets, feeShares);
  }

  /// @dev Computes and returns the fee shares (`feeShares`) to mint and the new vault's total assets
  /// (`newTotalAssets`).
  function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalAssets) {
    newTotalAssets = totalAssets();

    uint256 totalInterest = newTotalAssets.zeroFloorSub(lastTotalAssets);
    if (totalInterest != 0 && fee != 0) {
      // It is acknowledged that `feeAssets` may be rounded down to 0 if `totalInterest * fee < WAD`.
      uint256 feeAssets = totalInterest.mulDiv(fee, WAD);
      // The fee assets is subtracted from the total assets in this calculation to compensate for the fact
      // that total assets is already increased by the total interest (including the fee assets).
      feeShares = _convertToSharesWithTotals(feeAssets, totalSupply(), newTotalAssets - feeAssets, Math.Rounding.Floor);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

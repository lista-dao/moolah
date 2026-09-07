// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib } from "moolah/libraries/MathLib.sol";
import { ORACLE_PRICE_SCALE } from "moolah/libraries/ConstantsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";
import { ISlisBnbProvider } from "../provider/interfaces/IProvider.sol";
import { IStakeManager } from "../provider/interfaces/IStakeManager.sol";
import { ISlisBNBxMinter } from "./interfaces/ISlisBNBx.sol";
import { IYieldAccount } from "./interfaces/IYieldAccount.sol";

/// @title YieldAccount
/// @author Lista DAO
/// @notice Owns a Moolah slisBNB position for one account owner, accounted in BNB terms. Value above
///         the recorded BNB principal (exchange-rate growth) is skimmed to the treasury; the owner
///         can only withdraw and borrow against principal. slisBNBx accrues via SlisBNBProvider.
/// @dev Invariants:
///      1. Every position change goes through this contract; the only address it can authorize on
///         Moolah is `migrator`, never the OWNER key or an arbitrary address.
///      2. `_skim()` runs before every borrow and withdraw, so Moolah's own health check caps
///         borrowing at principal. No risk math is duplicated here.
///      3. `principalBnb` falls only with funds leaving or collateral seized (`_sync`). A pure
///         exchange-rate drop never lowers it — deficit cover is the protocol's call.
///      4. MANAGER owns config but cannot move funds, pick the migrator (DEFAULT_ADMIN does), or
///         raise `principalBnb` — so no single MANAGER key reaches the principal or can shrink the
///         protocol's yield claim. OWNER is immutable, so no role grant can hand a second address
///         control of the position.
///      5. `repay`, `skim` and `sync` are permissionless — all three only help.
/// @dev Follows MoolahVaultAccount (principal baseline + surplus-only harvest) with three deliberate
///      divergences: `skim` is permissionless rather than BOT-gated, since protocol yield must stay
///      collectable if a keyholder is unavailable and it can only ever reach `treasury`; there is no
///      `emergencyWithdraw`, because there the corpus is the protocol's own and here it is the
///      owner's; and there is no `increasePrincipal`, because unlike a plain share transfer into a
///      vault, every inflow here has a recording entry point — `depositBnb` / `depositSlisBnb` are
///      permissionless — so collateral supplied straight through the provider is a donation and is
///      correctly treated as yield.
contract YieldAccount is
  IYieldAccount,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;
  using MoolahBalancesLib for IMoolah;

  IMoolah public immutable MOOLAH;
  ISlisBnbProvider public immutable PROVIDER;
  IStakeManager public immutable STAKE_MANAGER;
  /// @dev slisBNB
  address public immutable TOKEN;
  /// @dev the single account owner. Immutable because one account has exactly one owner: it cannot
  ///      be granted to a second address the way a role could. Two consequences, both accepted: each
  ///      account needs its own implementation deploy, and rotating the key takes an upgrade.
  address public immutable OWNER;

  /// @dev fixed at init; a second market means a second proxy
  MarketParams public marketParams;
  Id public marketId;
  /// @dev the only value the owner can withdraw or borrow against
  uint256 public principalBnb;
  /// @dev collateral units after our last position change; a drop outside our flows means a
  ///      liquidation seized collateral — see `_sync`
  uint256 public trackedCollateral;
  /// @dev skim destination
  address public treasury;
  /// @dev skims below this BNB value are skipped (embedded) or revert (external)
  uint256 public minSkimBnb;
  /// @dev the only address `setMigratorAuthorization` can authorize on Moolah
  address public migrator;
  /// @dev borrow/withdraw destinations, MANAGER-managed
  EnumerableSet.AddressSet private receivers;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // protocol ops multisig
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role

  /// @dev events and errors live in IYieldAccount

  /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
  /// @param moolah the Moolah contract
  /// @param provider the lending SlisBNBProvider registered for the target market
  /// @param owner the account owner; borrow/withdraw/delegate
  constructor(address moolah, address provider, address owner) {
    require(moolah != address(0), ZeroAddress());
    require(provider != address(0), ZeroAddress());
    require(owner != address(0), ZeroAddress());
    require(ISlisBnbProvider(provider).MOOLAH() == moolah, InvalidMarket());

    OWNER = owner;

    MOOLAH = IMoolah(moolah);
    PROVIDER = ISlisBnbProvider(provider);
    STAKE_MANAGER = IStakeManager(ISlisBnbProvider(provider).STAKE_MANAGER());
    TOKEN = ISlisBnbProvider(provider).TOKEN();

    _disableInitializers();
  }

  /// @param admin DEFAULT_ADMIN_ROLE — upgrades, role administration (TimeLock)
  /// @param manager MANAGER — config, receiver whitelist, unpause
  /// @param pauser PAUSER — pause
  /// @param _marketParams the slisBNB market this account operates on
  /// @param _treasury skim destination
  /// @param _minSkimBnb minimum skim size in BNB value
  /// @param delegatee initial slisBNBx delegatee (typically the owner); 0 to skip
  /// @param _receivers initial borrow/withdraw destinations, must be non-empty
  function initialize(
    address admin,
    address manager,
    address pauser,
    MarketParams calldata _marketParams,
    address _treasury,
    uint256 _minSkimBnb,
    address delegatee,
    address[] calldata _receivers
  ) external initializer {
    require(admin != address(0), ZeroAddress());
    require(manager != address(0), ZeroAddress());
    require(pauser != address(0), ZeroAddress());
    require(_treasury != address(0), ZeroAddress());
    require(_marketParams.collateralToken == TOKEN, InvalidMarket());
    // an empty list deploys a contract whose borrow and withdraw revert on every call
    require(_receivers.length > 0, NoReceiver());

    Id id = _marketParams.id();
    require(MOOLAH.market(id).lastUpdate != 0, MarketNotCreated());
    // else deposits pass Moolah's ungated branch while provider withdrawals revert UNAUTHORIZED
    require(MOOLAH.providers(id, TOKEN) == address(PROVIDER), ProviderNotRegistered());

    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);
    // so MANAGER can revoke a stuck pauser key without a TimeLock proposal
    _setRoleAdmin(PAUSER, MANAGER);

    marketParams = _marketParams;
    marketId = id;
    treasury = _treasury;
    minSkimBnb = _minSkimBnb;

    for (uint256 i = 0; i < _receivers.length; ++i) {
      _addReceiver(_receivers[i]);
    }

    if (delegatee != address(0)) {
      address minter = PROVIDER.slisBNBxMinter();
      if (minter != address(0)) {
        ISlisBNBxMinter(minter).delegateAllTo(delegatee);
        emit SetDelegatee(delegatee);
      }
    }
  }

  modifier onlyOwner() {
    require(msg.sender == OWNER, NotAuthorized());
    _;
  }

  /* ----------------------------- deposits (permissionless) ----------------------------- */

  /// @dev stake BNB into slisBNB and supply it. Principal is credited with the BNB value of the
  ///      slisBNB actually received, never more than the position gained.
  function depositBnb() external payable nonReentrant whenNotPaused returns (uint256 slisAmount) {
    require(msg.value > 0, ZeroAmount());
    _sync();

    uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));
    STAKE_MANAGER.deposit{ value: msg.value }();
    slisAmount = IERC20(TOKEN).balanceOf(address(this)) - balanceBefore;

    _supplyAndRecord(slisAmount);
  }

  /// @dev open on purpose: the migrator deposits through here, and a third-party deposit only
  ///      gifts real principal to the owner
  function depositSlisBnb(uint256 amount) external nonReentrant whenNotPaused {
    require(amount > 0, ZeroAmount());
    _sync();

    IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);
    _supplyAndRecord(amount);
  }

  /* ----------------------------- owner actions ----------------------------- */

  /// @dev the skim runs first, so collateral value equals principal and Moolah's own health check
  ///      is the principal-based borrow limit
  function borrow(uint256 assets, address receiver) external onlyOwner nonReentrant whenNotPaused {
    require(assets > 0, ZeroAmount());
    require(receivers.contains(receiver), NotReceiver());

    _sync();
    _skim(false);

    MOOLAH.borrow(marketParams, assets, 0, address(this), receiver);
    emit Borrowed(receiver, assets);
  }

  /// @dev withdraw principal as slisBNB to a whitelisted receiver; `type(uint256).max` exits fully
  function withdraw(uint256 bnbAssets, address receiver) external onlyOwner nonReentrant whenNotPaused {
    require(bnbAssets > 0, ZeroAmount());
    require(receivers.contains(receiver), NotReceiver());

    _sync();
    bool exitAll = bnbAssets == type(uint256).max;
    // a full exit force-skims: minSkimBnb must not let a sub-threshold residual leave with the owner
    _skim(exitAll);

    uint256 coll = MOOLAH.position(marketId, address(this)).collateral;
    uint256 slisOut;
    uint256 bnbCharged;
    if (exitAll) {
      slisOut = coll;
      bnbCharged = principalBnb;
      principalBnb = 0;
    } else {
      require(bnbAssets <= principalBnb, ExceedsPrincipal());
      slisOut = STAKE_MANAGER.convertBnbToSnBnb(bnbAssets);
      require(slisOut <= coll, InsufficientCollateral());
      bnbCharged = bnbAssets;
      principalBnb -= bnbAssets;
    }
    require(slisOut > 0, ZeroAmount());

    // the provider is upgradeable — never report a payout the withdraw did not deliver
    uint256 balanceBefore = IERC20(TOKEN).balanceOf(receiver);
    PROVIDER.withdrawCollateral(marketParams, slisOut, address(this), receiver);
    require(IERC20(TOKEN).balanceOf(receiver) >= balanceBefore + slisOut, WithdrawShortfall());
    trackedCollateral = MOOLAH.position(marketId, address(this)).collateral;

    emit PrincipalWithdrawn(receiver, slisOut, bnbCharged, principalBnb);
  }

  /// @dev permissionless; `type(uint256).max` repays all by shares
  function repay(uint256 assets) external nonReentrant returns (uint256 repaidAssets, uint256 repaidShares) {
    MarketParams memory params = marketParams;
    IERC20 loanToken = IERC20(params.loanToken);

    if (assets == type(uint256).max) {
      MOOLAH.accrueInterest(params);
      Position memory pos = MOOLAH.position(marketId, address(this));
      require(pos.borrowShares > 0, ZeroAmount());
      Market memory m = MOOLAH.market(marketId);
      uint256 owed = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

      loanToken.safeTransferFrom(msg.sender, address(this), owed);
      loanToken.forceApprove(address(MOOLAH), owed);
      (repaidAssets, repaidShares) = MOOLAH.repay(params, 0, pos.borrowShares, address(this), "");
    } else {
      require(assets > 0, ZeroAmount());
      loanToken.safeTransferFrom(msg.sender, address(this), assets);
      loanToken.forceApprove(address(MOOLAH), assets);
      (repaidAssets, repaidShares) = MOOLAH.repay(params, assets, 0, address(this), "");
    }
    loanToken.forceApprove(address(MOOLAH), 0);

    // the shares path rounds in the market's favor by at most 1 wei; return anything left
    uint256 leftover = loanToken.balanceOf(address(this));
    if (leftover > 0) loanToken.safeTransfer(msg.sender, leftover);

    emit Repaid(msg.sender, repaidAssets, repaidShares);
  }

  /// @dev redirect the slisBNBx minted against this position
  function delegateSlisBNBx(address to) external onlyOwner {
    address minter = PROVIDER.slisBNBxMinter();
    require(minter != address(0), ZeroAddress());
    ISlisBNBxMinter(minter).delegateAllTo(to);
    emit SetDelegatee(to);
  }

  /// @dev the migrator is named in calldata, not just read from storage: an authorized address can
  ///      move the whole position, so a swap front-running this call must revert it.
  /// @dev OWNER or MANAGER — MANAGER needs it for a migration the owner does not run itself, and
  ///      can only ever authorize the address DEFAULT_ADMIN chose.
  function setMigratorAuthorization(address _migrator, bool enabled) external {
    require(msg.sender == OWNER || hasRole(MANAGER, msg.sender), NotAuthorized());
    require(_migrator != address(0), ZeroAddress());
    require(_migrator == migrator, NotMigrator());
    MOOLAH.setAuthorization(_migrator, enabled);
    emit MigratorAuthorization(_migrator, enabled);
  }

  /* ----------------------------- yield collection (permissionless) ----------------------------- */

  /// @dev collect value above principal to the treasury, capped so the position stays healthy
  function skim() external nonReentrant whenNotPaused returns (uint256 skimmed) {
    _sync();
    skimmed = _skim(false);
    require(skimmed > 0, NothingToSkim());
  }

  /// @dev converge principal after a liquidation seized collateral
  function sync() external {
    _sync();
  }

  /* ----------------------------- views ----------------------------- */

  function collateral() public view returns (uint256) {
    return MOOLAH.position(marketId, address(this)).collateral;
  }

  function collateralValueBnb() external view returns (uint256) {
    return STAKE_MANAGER.convertSnBnbToBnb(collateral());
  }

  /// @dev excludes interest since the last accrual
  function debt() external view returns (uint256) {
    Position memory pos = MOOLAH.position(marketId, address(this));
    if (pos.borrowShares == 0) return 0;
    Market memory m = MOOLAH.market(marketId);
    return uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
  }

  /// @dev collateral value above principal, in BNB. Clamps at 0 — the rate can fall.
  function claimableYield() public view returns (uint256) {
    uint256 value = STAKE_MANAGER.convertSnBnbToBnb(collateral());
    uint256 principal = principalBnb;
    return value > principal ? value - principal : 0;
  }

  /// @dev what a skim in this block could take, health-capped
  function skimmable() public view returns (uint256 slisAmount, uint256 bnbValue) {
    return _skimmable();
  }

  /// @dev backend dry-run. `claimable` is the accounting figure; `skimmableBnb` is what a skim in
  ///      this block can actually take. They differ when debt has grown against the health cap.
  function previewSkim() external view returns (uint256 claimable, uint256 skimmableSlis, uint256 skimmableBnb) {
    claimable = claimableYield();
    (skimmableSlis, skimmableBnb) = _skimmable();
  }

  /// @dev loan tokens the owner can borrow right now — the on-chain mirror of what `borrow` allows.
  ///      `borrow` skims first, so the cap prices off principal, never off unskimmed yield; and the
  ///      debt is the interest-accrued figure Moolah itself will use, so this does not drift stale.
  /// @dev the result still has to clear `MOOLAH.minLoan(marketParams)` on the resulting debt.
  function borrowable() external view returns (uint256) {
    (uint256 skimSlis, ) = _skimmable();
    uint256 postSkim = collateral() - skimSlis;
    if (postSkim == 0) return 0;

    uint256 maxDebt = postSkim.mulDivDown(MOOLAH.getPrice(marketParams), ORACLE_PRICE_SCALE).wMulDown(
      marketParams.lltv
    );
    uint256 owed = MOOLAH.expectedBorrowAssets(marketParams, address(this));
    if (maxDebt <= owed) return 0;

    // Moolah converts the requested assets to shares with toSharesUp and back with toAssetsUp, so
    // the debt it records lands 1 wei above the request. Quote one wei short of the cap, or
    // borrowing exactly this figure would trip its own health check.
    uint256 room = maxDebt - owed;
    return room > 1 ? room - 1 : 0;
  }

  /// @dev BNB value the owner can withdraw right now — the on-chain mirror of what `withdraw`
  ///      allows: principal is the hard ceiling, and with debt outstanding the health check caps it
  ///      further. `type(uint256).max` exits whatever this returns.
  function withdrawable() external view returns (uint256) {
    uint256 principal = principalBnb;
    if (principal == 0) return 0;

    (uint256 skimSlis, ) = _skimmable();
    uint256 postSkim = collateral() - skimSlis;
    uint256 owed = MOOLAH.expectedBorrowAssets(marketParams, address(this));
    if (owed == 0) return principal;

    uint256 minCollateral = owed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, MOOLAH.getPrice(marketParams));
    if (postSkim <= minCollateral) return 0;

    return Math.min(principal, STAKE_MANAGER.convertSnBnbToBnb(postSkim - minCollateral));
  }

  /// @dev all borrow/withdraw destinations
  function getReceivers() external view returns (address[] memory) {
    return receivers.values();
  }

  /// @dev whether `to` may receive borrowed assets or withdrawn principal
  function isReceiver(address to) public view returns (bool) {
    return receivers.contains(to);
  }

  /* ----------------------------- MANAGER config ----------------------------- */

  function setTreasury(address _treasury) external onlyRole(MANAGER) {
    require(_treasury != address(0), ZeroAddress());
    require(_treasury != treasury, AlreadySet());
    treasury = _treasury;
    emit SetTreasury(_treasury);
  }

  function setMinSkimBnb(uint256 _minSkimBnb) external onlyRole(MANAGER) {
    require(_minSkimBnb != minSkimBnb, AlreadySet());
    minSkimBnb = _minSkimBnb;
    emit SetMinSkimBnb(_minSkimBnb);
  }

  /// @dev DEFAULT_ADMIN, not MANAGER: MANAGER can flip authorization on, so letting it also pick
  ///      the address would put the principal within reach of one key
  function setMigrator(address _migrator) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_migrator != migrator, AlreadySet());
    // a previously authorized migrator must not stay authorized after being replaced
    if (migrator != address(0) && MOOLAH.isAuthorized(address(this), migrator)) {
      MOOLAH.setAuthorization(migrator, false);
      emit MigratorAuthorization(migrator, false);
    }
    migrator = _migrator;
    emit SetMigrator(_migrator);
  }

  function addReceiver(address to) external onlyRole(MANAGER) {
    _addReceiver(to);
  }

  function removeReceiver(address to) external onlyRole(MANAGER) {
    // initialize forbids an empty list; hold that invariant at runtime too
    require(receivers.length() > 1, NoReceiver());
    require(receivers.remove(to), ReceiverNotFound());

    emit RemoveReceiver(to);
  }

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /* ----------------------------- internals ----------------------------- */

  function _supplyAndRecord(uint256 slisAmount) internal {
    require(slisAmount > 0, ZeroAmount());
    // re-checked per deposit: the provider can be unregistered after init
    require(MOOLAH.providers(marketId, TOKEN) == address(PROVIDER), ProviderNotRegistered());
    uint256 bnbValue = STAKE_MANAGER.convertSnBnbToBnb(slisAmount);

    IERC20(TOKEN).forceApprove(address(PROVIDER), slisAmount);
    PROVIDER.supplyCollateral(marketParams, slisAmount, address(this), "");

    principalBnb += bnbValue;
    trackedCollateral = MOOLAH.position(marketId, address(this)).collateral;

    emit PrincipalDeposited(msg.sender, slisAmount, bnbValue, principalBnb);
  }

  /// @dev a unit drop outside our flows is a seizure; the seized VALUE is charged to principal, so
  ///      the owner bears the loss and the treasury's yield claim survives it. Clamping to the
  ///      remaining value instead would let unskimmed yield absorb the penalty.
  function _sync() internal {
    uint256 coll = MOOLAH.position(marketId, address(this)).collateral;
    uint256 tracked = trackedCollateral;
    if (coll < tracked) {
      uint256 seizedValue = STAKE_MANAGER.convertSnBnbToBnb(tracked - coll);
      uint256 p = principalBnb;
      if (seizedValue > 0 && p > 0) {
        uint256 newPrincipal = p > seizedValue ? p - seizedValue : 0;
        emit PrincipalSynced(p, newPrincipal);
        principalBnb = newPrincipal;
      }
    }
    if (coll != tracked) trackedCollateral = coll;
  }

  /// @param force ignore minSkimBnb (full-exit path)
  function _skim(bool force) internal returns (uint256) {
    MOOLAH.accrueInterest(marketParams);
    uint256 claimable = claimableYield();
    (uint256 amount, uint256 bnbValue) = _skimmable();
    if (amount == 0 || (!force && bnbValue < minSkimBnb)) return 0;

    address to = treasury;
    uint256 balanceBefore = IERC20(TOKEN).balanceOf(to);
    PROVIDER.withdrawCollateral(marketParams, amount, address(this), to);
    require(IERC20(TOKEN).balanceOf(to) >= balanceBefore + amount, WithdrawShortfall());
    trackedCollateral = MOOLAH.position(marketId, address(this)).collateral;

    emit YieldSkimmed(amount, bnbValue, claimable);
    return amount;
  }

  /// @dev rounding favors the owner: excess rounds down, the health floor rounds up
  function _skimmable() internal view returns (uint256 amount, uint256 bnbValue) {
    Position memory pos = MOOLAH.position(marketId, address(this));
    uint256 coll = pos.collateral;
    if (coll == 0) return (0, 0);

    uint256 value = STAKE_MANAGER.convertSnBnbToBnb(coll);
    uint256 principal = principalBnb;
    if (value <= principal) return (0, 0);
    uint256 excess = STAKE_MANAGER.convertBnbToSnBnb(value - principal);

    uint256 removable = coll;
    if (pos.borrowShares > 0) {
      Market memory m = MOOLAH.market(marketId);
      uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
      uint256 price = MOOLAH.getPrice(marketParams);
      uint256 minCollateral = borrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, price);
      removable = coll > minCollateral ? coll - minCollateral : 0;
    }

    amount = Math.min(Math.min(excess, removable), coll);
    bnbValue = STAKE_MANAGER.convertSnBnbToBnb(amount);
  }

  function _addReceiver(address to) private {
    require(to != address(0), ZeroAddress());
    require(receivers.add(to), DuplicateReceiver());

    emit AddReceiver(to);
  }

  /// @dev the authorization is the modifier
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IMoolahVault } from "moolah-vault/interfaces/IMoolahVault.sol";

/// @title MoolahVaultAccount
/// @author Lista DAO
/// @notice Owns the protocol's lisUSD MoolahVault position, records the principal explicitly, and
///         harvests only the surplus above it to a whitelisted set of destinations.
/// @dev Deliberate design choices, written down here so they are not re-reported as findings:
///      1. `initialize` is permissionless and this implementation is generic. The constructor calls
///         `_disableInitializers()`, so the implementation itself can never be initialized, and every
///         proxy has its own storage — a third party pointing their own proxy at this implementation
///         cannot reach this instance. Which proxy is the protocol's is established by its role
///         holders and the address registry, not by the code.
///      2. `_authorizeUpgrade` has an empty body on purpose: the authorization IS the
///         `onlyRole(DEFAULT_ADMIN_ROLE)` modifier, and DEFAULT_ADMIN_ROLE is the protocol TimeLock.
///         Every other upgradeable contract in this repo is written the same way.
///      3. MANAGER is the role admin of BOT and also owns the recipient whitelist, so a compromised
///         MANAGER key can add its own address and grant itself BOT — that surface is accepted, not
///         overlooked, and `emergencyWithdraw` puts the whole position within its reach in one call.
///         MANAGER is B0c6, which is also `principalOwner`: the multisig that owns these funds and
///         can already pull the entire principal back to itself through `withdrawPrincipal`. What no
///         MANAGER call can do is choose a destination — principal and the emergency exit pay
///         `principalOwner`, yield pays whitelisted recipients, and `setPrincipalOwner` is
///         DEFAULT_ADMIN_ROLE-only. BOT's and PAUSER's admin is MANAGER rather than
///         DEFAULT_ADMIN_ROLE because rotating a leaked bot key — or revoking a pauser key that is
///         holding the contract down — must not wait on a 24h TimeLock proposal.
///      4. `principal` is raised by MANAGER (`depositPrincipal`, `increasePrincipal`) and lowered
///         only against funds actually leaving (`withdrawPrincipal`, `emergencyWithdraw`), with one
///         exception: `emergencyWithdraw` resets it to 0, because it always empties the position and
///         an empty position has no baseline to keep. That reset cannot be used to turn principal
///         into harvestable yield: it only fires once the whole position has left, which leaves
///         `claimableYield()` at 0 too. Nothing else can lower the baseline — doing so on a position
///         that stays is the one action that would turn principal into harvestable yield.
///      5. `increasePrincipal` is not bounded by `totalAssets()`. Raising the baseline can only
///         shrink `claimableYield()`, so it can never widen what BOT may take, and after a loss the
///         position legitimately sits below `principal`.
///      6. After an exact claim the position can sit up to one share-wei's worth of assets BELOW
///         `principal`, because `vault.withdraw` burns ceil-rounded shares. That deficit is a floor,
///         not a ratchet: `claimableYield()` is 0 until NAV recovers, so further claims cannot
///         deepen it, and BOT can never reach it.
///      7. There is no ERC20 rescue and no sweep. `claimYield` withdraws exactly what it pays out,
///         so nothing accumulates here in normal operation; anything sent here by mistake is ignored
///         by every accounting view and recovered, if ever, by upgrade.
///      8. `payments` may name one destination twice and may carry zero-amount entries. Amounts are
///         the backend's decision; the contract enforces only that every destination is whitelisted
///         and that the total does not exceed `claimableYield()`. A zero-amount entry is still
///         whitelist-checked.
///      9. No exit lets its caller name a destination: principal and emergency exits pay
///         `principalOwner`, yield pays whitelisted recipients. Read with note 3, that means a
///         compromised MANAGER can redirect the surplus but never the corpus, and a compromised BOT
///         can move the surplus only to addresses MANAGER has already approved.
contract MoolahVaultAccount is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

  /// @param to destination, must be whitelisted
  /// @param amount lisUSD
  struct Payment {
    address to;
    uint256 amount;
  }

  /// @dev the vault whose shares this contract holds. Fixed at init on purpose: there is no setter,
  ///      and a second vault means a second proxy.
  IMoolahVault public vault;
  /// @dev cached `vault.asset()`. The vault sets its asset once, in its own initializer, and exposes
  ///      no setter, so this cannot go stale.
  IERC20 public asset;
  /// @dev the only address the principal and emergency exits can pay
  address public principalOwner;
  uint256 public principal;
  mapping(address => bool) public isYieldRecipient;
  address[] private yieldRecipients;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role

  event PrincipalDeposited(address indexed from, uint256 assets, uint256 principal);
  event PrincipalWithdrawn(address indexed to, uint256 assets, uint256 principal);
  event PrincipalIncreased(uint256 assets, uint256 principal);
  event EmergencyWithdrawn(address indexed to, uint256 shares);
  event YieldClaimed(uint256 total, uint256 claimableAtCall);
  event YieldPaid(address indexed to, uint256 amount);
  event AddYieldRecipient(address indexed to);
  event RemoveYieldRecipient(address indexed to);
  event SetPrincipalOwner(address indexed principalOwner);

  error ZeroAddress();
  error ZeroAmount();
  error AlreadySet();
  error NoYieldRecipient();
  error NotYieldRecipient();
  error DuplicateRecipient();
  error RecipientNotFound();
  error ExceedsPrincipal();
  error ExceedsClaimable();
  error ZeroShares();
  error WithdrawShortfall();
  error SharesRemaining();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @dev initialize contract. Roles are granted to their FINAL holders; the deployer takes none.
  /// @dev permissionless by design — note 1 in the contract header.
  /// @param admin DEFAULT_ADMIN_ROLE — upgrades, setPrincipalOwner, role administration
  /// @param manager MANAGER — principal movement, recipient whitelist, unpause, BOT/PAUSER admin
  /// @param bot BOT — claimYield
  /// @param pauser PAUSER — pause
  /// @param _vault the MoolahVault whose shares this contract holds
  /// @param _principalOwner the only address principal can be withdrawn to
  /// @param _principal starting principal, lisUSD. May exceed the position value at init.
  /// @param _yieldRecipients initial claimYield destinations, must be non-empty
  function initialize(
    address admin,
    address manager,
    address bot,
    address pauser,
    address _vault,
    address _principalOwner,
    uint256 _principal,
    address[] calldata _yieldRecipients
  ) external initializer {
    require(admin != address(0), ZeroAddress());
    require(manager != address(0), ZeroAddress());
    require(bot != address(0), ZeroAddress());
    require(pauser != address(0), ZeroAddress());
    require(_vault != address(0), ZeroAddress());
    require(_principalOwner != address(0), ZeroAddress());
    // an empty list deploys a contract whose claimYield reverts on every call
    require(_yieldRecipients.length > 0, NoYieldRecipient());

    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
    _grantRole(PAUSER, pauser);
    // so MANAGER can rotate the bot key, or revoke a pauser key that is holding the contract down,
    // without a TimeLock proposal
    _setRoleAdmin(BOT, MANAGER);
    _setRoleAdmin(PAUSER, MANAGER);

    vault = IMoolahVault(_vault);
    asset = IERC20(IMoolahVault(_vault).asset());
    principalOwner = _principalOwner;
    principal = _principal;

    for (uint256 i = 0; i < _yieldRecipients.length; ++i) {
      _addYieldRecipient(_yieldRecipients[i]);
    }
  }

  /// @dev current lisUSD value of the position. C3: convertToAssets, not
  ///      totalAssets * shares / totalSupply, so accrued-but-unminted fee shares are netted out.
  function totalAssets() public view returns (uint256) {
    return vault.convertToAssets(vault.balanceOf(address(this)));
  }

  /// @dev NAV surplus above principal. Clamps at 0 — C1 means the position value can fall.
  function claimableYield() public view returns (uint256) {
    uint256 assets = totalAssets();
    return assets > principal ? assets - principal : 0;
  }

  /// @dev backend dry-run. `claimable` is the accounting figure; `claimableNow` is what a claim in
  ///      this block can actually take. They differ exactly when the vault is liquidity-starved.
  function previewClaim() external view returns (uint256 claimable, uint256 withdrawable, uint256 claimableNow) {
    claimable = claimableYield();
    withdrawable = vault.maxWithdraw(address(this));
    claimableNow = Math.min(claimable, withdrawable);
  }

  /// @dev pull lisUSD from the caller and supply it to the vault, raising principal by the same
  ///      nominal amount. Requires this contract on the vault's deposit whitelist.
  function depositPrincipal(uint256 assets) external onlyRole(MANAGER) nonReentrant whenNotPaused {
    require(assets > 0, ZeroAmount());

    asset.safeTransferFrom(msg.sender, address(this), assets);
    asset.forceApprove(address(vault), assets);
    uint256 shares = vault.deposit(assets, address(this));
    // a deposit too small to mint a share must not raise principal for free
    require(shares > 0, ZeroShares());
    principal += assets;

    emit PrincipalDeposited(msg.sender, assets, principal);
  }

  /// @dev redeem principal to principalOwner. The caller cannot name a destination.
  /// @dev whenNotPaused: a halted contract must not let principal leave piecemeal. Pause is not only
  ///      a bot kill-switch — it is also the state an incident puts this contract in, and while it
  ///      holds, the only sanctioned exit is `emergencyWithdraw`, which takes the whole position back
  ///      to principalOwner in one move and cannot be walked down amount by amount. MANAGER holds
  ///      `unpause`, so this is a speed bump for MANAGER, not a trap.
  /// @dev checks-effects-interactions: principal is decremented before the vault call.
  function withdrawPrincipal(uint256 assets) external onlyRole(MANAGER) nonReentrant whenNotPaused {
    require(assets > 0, ZeroAmount());
    require(assets <= principal, ExceedsPrincipal());

    principal -= assets;
    vault.withdraw(assets, principalOwner, address(this));

    emit PrincipalWithdrawn(principalOwner, assets, principal);
  }

  /// @dev raise the principal baseline without moving funds. Vault shares can be transferred in by a
  ///      plain ERC20 transfer, which bypasses depositPrincipal — that position would otherwise read
  ///      as harvestable yield and be paid out as such. This is how a top-up is recorded when it
  ///      arrives as shares instead of lisUSD.
  /// @dev NOT part of the launch. At launch the baseline comes from `initialize` and B0c6 only
  ///      transfers its shares in — calling this on top of that would count the same corpus twice,
  ///      and the baseline cannot be lowered again. There are exactly two sanctioned ways to move the
  ///      baseline afterwards:
  ///        1. `depositPrincipal` / `withdrawPrincipal` — lisUSD in or out, baseline follows the funds
  ///           in the same call, nothing to pair up;
  ///        2. a share transfer plus this call, in ONE transaction.
  /// @dev for route 2 the pairing is mandatory: a Safe MultiSend batch, never two separate Safe
  ///      transactions. Nothing on-chain can enforce it — a plain ERC20 share transfer has no hook to
  ///      intercept. Split across two transactions, the whole transferred position reads as claimable
  ///      yield in between, and a BOT harvest landing in that window pays the corpus out as yield to a
  ///      whitelisted destination.
  /// @dev MANAGER-only and raise-only — notes 4 and 5 in the contract header. Raising the baseline
  ///      can only shrink claimableYield(), so it cannot widen what BOT may take, and it redirects
  ///      nothing: withdrawPrincipal still pays principalOwner only.
  /// @dev no nonReentrant and no whenNotPaused: no external call, no fund movement, and a correction
  ///      that only shrinks claimableYield() must stay available during an incident.
  /// @param assets the COST BASIS of the shares being recorded — the lisUSD that was paid for them —
  ///        never their current `vault.convertToAssets(shares)` value. The two differ by exactly the
  ///        yield already accrued on them, and recording the market value would swallow that backlog
  ///        into principal, out of BOT's reach forever. That is why the amount is a parameter and is
  ///        not computed on-chain — the cost basis does not exist on-chain.
  function increasePrincipal(uint256 assets) external onlyRole(MANAGER) {
    require(assets > 0, ZeroAmount());

    principal += assets;

    emit PrincipalIncreased(assets, principal);
  }

  /// @dev harvest NAV surplus and fan it out. Costs and residual are the caller's decision; the
  ///      contract enforces only that every destination is whitelisted and that the total does not
  ///      exceed claimableYield().
  /// @dev one vault.withdraw for the whole total, then plain transfers. Each withdraw-queue walk is
  ///      independently all-or-nothing (C2), so one walk beats N.
  /// @dev duplicate destinations and zero-amount entries are allowed — note 8 in the contract header.
  /// @param payments destinations and amounts, lisUSD
  /// @return total the amount harvested
  function claimYield(
    Payment[] calldata payments
  ) external onlyRole(BOT) nonReentrant whenNotPaused returns (uint256 total) {
    uint256 len = payments.length;
    for (uint256 i = 0; i < len; ++i) {
      require(isYieldRecipient[payments[i].to], NotYieldRecipient());
      total += payments[i].amount;
    }
    require(total > 0, ZeroAmount());

    uint256 claimable = claimableYield();
    require(total <= claimable, ExceedsClaimable());

    uint256 balanceBefore = asset.balanceOf(address(this));
    vault.withdraw(total, address(this), address(this));
    // the vault is upgradeable — never pay out of a balance the withdraw did not deliver
    require(asset.balanceOf(address(this)) >= balanceBefore + total, WithdrawShortfall());

    for (uint256 i = 0; i < len; ++i) {
      uint256 amount = payments[i].amount;
      if (amount == 0) continue;
      asset.safeTransfer(payments[i].to, amount);
      emit YieldPaid(payments[i].to, amount);
    }

    emit YieldClaimed(total, claimable);
  }

  /// @dev hand the entire position to principalOwner as vault shares — the one exit that ignores the
  ///      principal/yield split, because the shares carry both.
  /// @dev MANAGER only — B0c6, which is also principalOwner. Deliberate: an exit gated behind a 24h
  ///      TimeLock proposal is not an emergency exit, and the funds are B0c6's own. The role change
  ///      buys speed and independence from queue liquidity, not a new destination: the shares can only
  ///      go to principalOwner, and `setPrincipalOwner` stays DEFAULT_ADMIN_ROLE-only (notes 3, 4).
  ///      DEFAULT_ADMIN_ROLE keeps the upgrade key and administers MANAGER, so it can grant itself
  ///      MANAGER and take this route if B0c6 is unavailable.
  /// @dev NOT whenNotPaused — the incident that pauses this contract is the reason to call it.
  /// @dev no arguments, and it transfers the shares instead of redeeming them. Both are deliberate.
  ///      Always taking the whole balance means a Safe transaction signed hours before it executes
  ///      cannot carry a stale amount. Transferring shares means the exit never walks the withdraw
  ///      queue, so it is NOT bounded by C2: withdrawPrincipal and claimYield can both revert
  ///      NotEnoughLiquidity() while this call still succeeds — which is exactly the state an
  ///      emergency is likely to find. principalOwner redeems on its own schedule afterwards.
  /// @dev the destination is principalOwner, never a caller-supplied address — same rule as
  ///      withdrawPrincipal, so no exit in this contract lets its caller pick where funds go.
  /// @dev principal is zeroed before the external call (state first) and unconditionally: the position
  ///      is empty afterwards, and an empty position has no baseline to keep (note 4).
  /// @dev the balance is re-read after the transfer because the vault is upgradeable: an ERC20
  ///      transfer that returns true without moving anything would otherwise leave the baseline at 0
  ///      with the position still held here. SafeERC20 checks the return value, not the effect.
  /// @return shares the vault shares sent to principalOwner
  function emergencyWithdraw() external onlyRole(MANAGER) nonReentrant returns (uint256 shares) {
    shares = vault.balanceOf(address(this));
    require(shares > 0, ZeroShares());

    principal = 0;

    IERC20(address(vault)).safeTransfer(principalOwner, shares);
    require(vault.balanceOf(address(this)) == 0, SharesRemaining());

    emit EmergencyWithdrawn(principalOwner, shares);
  }

  /// @dev get all whitelisted claimYield destinations
  function getYieldRecipients() external view returns (address[] memory) {
    return yieldRecipients;
  }

  /// @dev add a claimYield destination
  function addYieldRecipient(address to) external onlyRole(MANAGER) {
    _addYieldRecipient(to);
  }

  /// @dev remove a claimYield destination
  function removeYieldRecipient(address to) external onlyRole(MANAGER) {
    require(isYieldRecipient[to], RecipientNotFound());
    // initialize forbids an empty list; hold that invariant at runtime too
    require(yieldRecipients.length > 1, NoYieldRecipient());
    delete isYieldRecipient[to];

    uint256 len = yieldRecipients.length;
    for (uint256 i = 0; i < len; ++i) {
      if (yieldRecipients[i] == to) {
        yieldRecipients[i] = yieldRecipients[len - 1];
        yieldRecipients.pop();
        break;
      }
    }

    emit RemoveYieldRecipient(to);
  }

  /// @dev change the address principal is withdrawn to. DEFAULT_ADMIN only — MANAGER must not be
  ///      able to redirect principal away from the multisig.
  function setPrincipalOwner(address _principalOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_principalOwner != address(0), ZeroAddress());
    require(_principalOwner != principalOwner, AlreadySet());
    principalOwner = _principalOwner;

    emit SetPrincipalOwner(_principalOwner);
  }

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _addYieldRecipient(address to) private {
    require(to != address(0), ZeroAddress());
    require(!isYieldRecipient[to], DuplicateRecipient());
    isYieldRecipient[to] = true;
    yieldRecipients.push(to);

    emit AddYieldRecipient(to);
  }

  /// @dev empty body on purpose — note 2 in the contract header. The authorization is the modifier.
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

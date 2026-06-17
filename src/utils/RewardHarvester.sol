// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IClisBNBLaunchPoolDistributor } from "./interfaces/IClisBNBLaunchPoolDistributor.sol";
import { ICollateralYieldVault } from "../moolah-vault/interfaces/ICollateralYieldVault.sol";

/// @title RewardHarvester
/// @author Lista DAO
/// @notice Intermediate contract for the CollateralYieldVault. The backend bot calls `harvest` to claim launchpool BNB
///         rewards from the distributor (paid to THIS contract, as `_account` is hardcoded to `address(this)`), then
///         injects the BNB into the vault via `increaseVaultAssets`. Claimed BNB can only flow into the vault.
contract RewardHarvester is UUPSUpgradeable, AccessControlEnumerableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // config / rescue
  bytes32 public constant BOT = keccak256("BOT"); // backend operator

  /// @notice The launchpool reward distributor.
  IClisBNBLaunchPoolDistributor public immutable DISTRIBUTOR;
  /// @notice The CollateralYieldVault to compound into.
  ICollateralYieldVault public immutable VAULT;

  struct ClaimParams {
    uint64 epochId;
    uint256 amount;
    bytes32[] proof;
  }

  event Harvested(uint256 claimCount, uint256 bnbInjected);
  event Rescued(address indexed token, address indexed to, uint256 amount);

  error InsufficientReward();
  error NothingToCompound();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _distributor, address _vault) {
    require(_distributor != address(0) && _vault != address(0), "zero address");
    _disableInitializers();
    DISTRIBUTOR = IClisBNBLaunchPoolDistributor(_distributor);
    VAULT = ICollateralYieldVault(_vault);
  }

  function initialize(address admin, address manager, address bot) external initializer {
    require(admin != address(0) && manager != address(0) && bot != address(0), "zero address");
    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
  }

  /// @notice Claim launchpool BNB for the given epochs (to this contract) and compound it into the vault.
  /// @param claims Per-epoch claim data (epochId, amount, Merkle proof). `_account` is hardcoded to this contract,
  ///        so the distributor pays the harvester directly and the BOT cannot redirect the funds.
  /// @param minBNBOut Minimum total BNB balance required after claiming (anti-anomaly / sanity bound).
  /// @dev NOTICE: distributor `claim` is permissionless and always pays this harvester, so anyone can claim extra
  ///      epochs; `harvest` compounds the full balance, so the injected amount may exceed sum(claims[i].amount).
  ///      Only ever raises share price. `minBNBOut` is a lower bound, not an equality.
  /// @dev NOTICE: if the Moolah market is paused, `supplyCollateral` (and thus `harvest`) reverts. While paused,
  ///      claim directly on the distributor (funds still land here via the fixed `_account`) and call `harvest`
  ///      after unpause to avoid epochs expiring unclaimed.
  function harvest(ClaimParams[] calldata claims, uint256 minBNBOut) external onlyRole(BOT) nonReentrant {
    uint256 claimCount;
    for (uint256 i; i < claims.length; ++i) {
      // The Merkle tree's `_account` is configured off-chain to this RewardHarvester, so the distributor pays the
      // launchpool BNB to this contract — receiving it on behalf of the vault — and we then compound it in.
      // Skip already-claimed epochs to keep the batch idempotent.
      if (DISTRIBUTOR.claimed(claims[i].epochId, address(this))) continue;
      DISTRIBUTOR.claim(claims[i].epochId, address(this), claims[i].amount, claims[i].proof);
      ++claimCount;
    }

    uint256 bnbBal = address(this).balance;
    if (bnbBal == 0) revert NothingToCompound();
    if (bnbBal < minBNBOut) revert InsufficientReward();

    VAULT.increaseVaultAssets{ value: bnbBal }();

    // Emit the number of epochs actually claimed this call (already-claimed epochs are skipped above).
    emit Harvested(claimCount, bnbBal);
  }

  /// @notice Emergency recovery of stranded tokens/BNB (e.g. a non-BNB reward token). Manager-only.
  /// @dev NOTICE: since distributor claims are permissionless, MANAGER can claim all rewards here and drain them via
  ///      `rescue`. Use a strong multisig for the MANAGER role to mitigate key-compromise.
  function rescue(address token, address to, uint256 amount) external onlyRole(MANAGER) {
    require(to != address(0), "zero to");
    if (token == address(0)) {
      (bool ok, ) = payable(to).call{ value: amount }("");
      require(ok, "bnb transfer failed");
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
    emit Rescued(token, to, amount);
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /// @notice Receive launchpool BNB rewards from the distributor.
  receive() external payable {}
}

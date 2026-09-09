// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMoolah, Id } from "moolah/interfaces/IMoolah.sol";
import { ISlisBnbProvider } from "../../provider/interfaces/IProvider.sol";
import { IStakeManager } from "../../provider/interfaces/IStakeManager.sol";

/// @title IYieldAccount
/// @notice Events, errors and the runtime surface of YieldAccount.
interface IYieldAccount {
  /* ----------------------------- events ----------------------------- */

  event PrincipalDeposited(address indexed from, uint256 slisAmount, uint256 bnbValue, uint256 principal);
  event PrincipalWithdrawn(address indexed to, uint256 slisAmount, uint256 bnbCharged, uint256 principal);
  event PrincipalSynced(uint256 oldPrincipal, uint256 newPrincipal);
  event Borrowed(address indexed to, uint256 assets);
  event Repaid(address indexed from, uint256 assets, uint256 shares);
  event YieldSkimmed(uint256 slisAmount, uint256 bnbValue, uint256 claimableAtCall);
  event MigratorAuthorization(address indexed migrator, bool enabled);
  event SetDelegatee(address indexed delegatee);
  event SetTreasury(address indexed treasury);
  event SetMinSkimBnb(uint256 minSkimBnb);
  event SetMigrator(address indexed migrator);
  event AddReceiver(address indexed to);
  event RemoveReceiver(address indexed to);

  /* ----------------------------- errors ----------------------------- */

  error ZeroAddress();
  error ZeroAmount();
  error AlreadySet();
  error InvalidMarket();
  error MarketNotCreated();
  error NotReceiver();
  error NotMigrator();
  error NotAuthorized();
  error ProviderNotRegistered();
  error ExceedsPrincipal();
  error NothingToSkim();
  error InsufficientCollateral();
  error DuplicateReceiver();
  error ReceiverNotFound();
  error NoReceiver();
  error WithdrawShortfall();
  error MinterNotSet();

  /* ----------------------------- immutables ----------------------------- */

  function MOOLAH() external view returns (IMoolah);

  function PROVIDER() external view returns (ISlisBnbProvider);

  function STAKE_MANAGER() external view returns (IStakeManager);

  /// @notice slisBNB
  function TOKEN() external view returns (address);

  /// @notice the single account owner; borrow/withdraw/delegate
  function OWNER() external view returns (address);

  /* ----------------------------- state ----------------------------- */

  function marketParams() external view returns (address, address, address, address, uint256);

  function marketId() external view returns (Id);

  /// @notice the only value the owner can withdraw or borrow against
  function principalBnb() external view returns (uint256);

  /// @notice collateral units after the last position change; a drop outside our flows is a seizure
  function trackedCollateral() external view returns (uint256);

  function treasury() external view returns (address);

  function minSkimBnb() external view returns (uint256);

  /// @notice the only address `setMigratorAuthorization` can authorize on Moolah
  function migrator() external view returns (address);

  function isReceiver(address to) external view returns (bool);

  function getReceivers() external view returns (address[] memory);

  /* ----------------------------- accounting views ----------------------------- */

  function collateral() external view returns (uint256);

  function collateralValueBnb() external view returns (uint256);

  /// @notice debt in loan tokens, excluding interest since the last accrual
  function debt() external view returns (uint256);

  /// @notice collateral value above principal, in BNB. Clamps at 0.
  function claimableYield() external view returns (uint256);

  /// @notice what a skim in this block could take, health-capped
  function skimmable() external view returns (uint256 slisAmount, uint256 bnbValue);

  /// @notice `claimable` is the accounting figure; `skimmableBnb` is what a skim can take now
  function previewSkim() external view returns (uint256 claimable, uint256 skimmableSlis, uint256 skimmableBnb);

  /// @notice loan tokens the owner can borrow right now; mirrors what `borrow` allows
  function borrowable() external view returns (uint256);

  /// @notice BNB value the owner can withdraw right now; mirrors what `withdraw` allows
  function withdrawable() external view returns (uint256);

  /* ----------------------------- deposits (permissionless) ----------------------------- */

  /// @notice stake native BNB into slisBNB and supply it as collateral
  function depositBnb() external payable returns (uint256 slisAmount);

  /// @notice supply slisBNB as collateral, recording its BNB value as principal
  function depositSlisBnb(uint256 amount) external;

  /* ----------------------------- owner actions ----------------------------- */

  function borrow(uint256 assets, address receiver) external;

  /// @notice withdraw principal as slisBNB; `type(uint256).max` exits fully
  function withdraw(uint256 bnbAssets, address receiver) external;

  function delegateSlisBNBx(address to) external;

  /// @notice OWNER or MANAGER; `_migrator` must equal `migrator()`
  function setMigratorAuthorization(address _migrator, bool enabled) external;

  /* ----------------------------- permissionless ----------------------------- */

  /// @notice `type(uint256).max` repays all by shares
  function repay(uint256 assets) external returns (uint256 repaidAssets, uint256 repaidShares);

  /// @notice collect value above principal to the treasury
  function skim() external returns (uint256 skimmed);

  /// @notice converge principal after a liquidation seized collateral
  function sync() external;

  /* ----------------------------- admin ----------------------------- */

  function setTreasury(address _treasury) external;

  function setMinSkimBnb(uint256 _minSkimBnb) external;

  function setMigrator(address _migrator) external;

  function addReceiver(address to) external;

  function removeReceiver(address to) external;

  function pause() external;

  function unpause() external;
}

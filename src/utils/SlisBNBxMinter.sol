// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Moolah } from "moolah/Moolah.sol";
import { ISlisBNBx, ISlisBNBxModule } from "./interfaces/ISlisBNBx.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";

/**
 * @title slisBNBx Minter Contract
 * @author Lista DAO
 * @notice This contract allows users to stake supported collateral tokens (e.g. slisBNB and smart-LP) and receive slisBNBx in return to participate Binance Launchpool.
 */
contract SlisBNBxMinter is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;

  ISlisBNBx public immutable SLISBNB_X;
  uint24 constant DENOMINATOR = 1_000_000;

  struct MPCWallet {
    address walletAddress;
    uint256 balance;
    uint256 cap;
  }

  struct ModuleConfig {
    uint24 discount; // for LP modules, a discount should be applied before calculating user's slisBNBx; set to 100% to disable the module
    uint24 feeRate; // portion of slisBNBx to be taken as fee
    address moduleAddress; // module address used to distinguish if an address is a valid module
  }

  struct UserModuleBalance {
    uint256 userPart; // slisBNBx balance allocated to user
    uint256 feePart; // slisBNBx balance allocated as fee
  }

  /// @dev module address => ModuleConfig
  mapping(address => ModuleConfig) public moduleConfig;
  /// @dev user address => module address => UserModuleBalance
  mapping(address => mapping(address => UserModuleBalance)) public userModuleBalance;
  /// @dev account => delegatee; no partial delegation
  mapping(address => address) public delegation;
  /// @dev user account => total amount of slisBNBx minted to user from all modules
  /// @notice when changing delegation, need to burn all slisBNBx from old delegatee and mint to new delegatee
  mapping(address => uint256) public userTotalBalance;

  /// @dev mpc wallets to receive fee
  MPCWallet[] public mpcWallets;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  /* ------------------ Events ------------------ */
  event Rebalance(address account, uint256 latestModuleBalance, address module, uint256 latestTotalBalance);
  event UserModuleRebalanced(address account, address module, uint256 userPart, uint256 feePart);
  event ChangeDelegateTo(address account, address oldDelegatee, address newDelegatee, uint256 amount);
  event MpcWalletCapChanged(address wallet, uint256 oldCap, uint256 newCap);
  event MpcWalletRemoved(address wallet);
  event MpcWalletAdded(address wallet, uint256 cap);
  event ModuleConfigUpdated(address module, uint24 discount, uint24 feeRate, bool enabled);

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param _slisBNBx The address of the slisBNBx
  constructor(address _slisBNBx) {
    require(_slisBNBx != address(0), "token is the zero address");

    SLISBNB_X = ISlisBNBx(_slisBNBx);
    _disableInitializers();
  }

  /**
   * @notice Initialize the SlisBNBxMinter contract
   * @param admin The address of the admin
   * @param manager The address of the manager
   * @param _modules The list of modules to be added
   * @param _configs The list of module configurations
   */
  function initialize(
    address admin,
    address manager,
    address[] calldata _modules,
    ModuleConfig[] calldata _configs
  ) public initializer {
    require(admin != address(0), "admin is the zero address");
    require(manager != address(0), "manager is the zero address");
    require(_modules.length == _configs.length, "modules and configs length mismatch");

    for (uint256 i = 0; i < _modules.length; i++) {
      address module = _modules[i];
      ModuleConfig memory config = _configs[i];
      require(module != address(0), "module is the zero address");
      require(module == config.moduleAddress, "module address mismatch");
      require(config.feeRate <= DENOMINATOR, "userLpRate invalid");
      require(config.discount <= DENOMINATOR, "discount invalid");

      moduleConfig[module] = config;
      emit ModuleConfigUpdated(module, config.discount, config.feeRate, true);
    }

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  /**
   * @notice Rebalance user slisBNBx tokens; can only be called by a module
   * @param account The user address
   * @return rebalanced and latestLpBalance whether rebalanced, new user slisBNBx balance
   */
  function rebalance(address account) external returns (bool rebalanced, uint256 latestModuleBalance) {
    require(account != address(0), "zero account address");

    ModuleConfig memory config = moduleConfig[msg.sender];
    require(config.moduleAddress == msg.sender, "unauthorized module");

    // rebalance user's slisBNBx
    (rebalanced, latestModuleBalance) = _rebalanceUserLp(account, msg.sender);

    emit Rebalance(account, latestModuleBalance, msg.sender, userTotalBalance[account]);
  }

  /**
   * @notice User's available slisBNBx might lower than the burn amount
   *         due to the change of exchangeRate, feeRate or the value of the LP token fluctuates from time to time
   *         i.e. userLp[account] might < slisBNBx.balanceOf(holder)
   * @param holder lp token holder
   * @param amount amount to burn
   * @return actual burned amount
   */
  function _safeBurnLp(address holder, uint256 amount) internal returns (uint256) {
    uint256 availableBalance = SLISBNB_X.balanceOf(holder);
    if (amount <= availableBalance) {
      SLISBNB_X.burn(holder, amount);
      return amount;
    } else if (availableBalance > 0) {
      // existing users do not have enough slisBNBx
      SLISBNB_X.burn(holder, availableBalance);
      return availableBalance;
    }
    return 0;
  }

  /**
   * @dev mint/burn slisBNBx to sync user's slisBNBx with token balance
   * @param account user address to sync
   * @param _module module address
   * @return (bool, uint256) whether rebalanced, new user slisBNBx balance
   */
  function _rebalanceUserLp(address account, address _module) internal returns (bool, uint256) {
    ModuleConfig memory config = moduleConfig[_module];

    // ---- [1] New total slisBNBx for user in this module
    uint256 stakedAmount = ISlisBNBxModule(_module).getUserBalanceInBnb(account);
    // Total slisBNBx (User + Reserve) of a module
    uint256 amountAfterDiscount = (stakedAmount * (DENOMINATOR - config.discount)) / DENOMINATOR;
    // slisBNBx as fee
    uint256 newReservedLp = (amountAfterDiscount * config.feeRate) / DENOMINATOR;
    // User's slisBNBx
    uint256 newUserLp = amountAfterDiscount - newReservedLp;

    // ---- [2] Current user slisBNBx and reserved slisBNBx
    UserModuleBalance storage userModuleBal = userModuleBalance[account][_module];
    uint256 oldUserLp = userModuleBal.userPart;
    uint256 oldReservedLp = userModuleBal.feePart;

    // handle slisBNBx balance unchanged
    if (oldUserLp == newUserLp && oldReservedLp == newReservedLp) {
      return (false, oldUserLp);
    }

    // ---- [3] handle fee
    if (oldReservedLp > newReservedLp) {
      _burnFromMPCs(oldReservedLp - newReservedLp);
    } else if (oldReservedLp < newReservedLp) {
      _mintToMPCs(newReservedLp - oldReservedLp);
    }
    userModuleBal.feePart = newReservedLp;

    // ---- [4] handle user slisBNBx and delegation
    address holder = delegation[account];
    // account as the default delegatee if holder is not set
    if (holder == address(0)) {
      holder = account;
      delegation[account] = holder;
    }
    if (oldUserLp > newUserLp) {
      uint256 cut = oldUserLp - newUserLp;
      _safeBurnLp(holder, cut);
      uint256 beforeTotal = userTotalBalance[account];
      userTotalBalance[account] = beforeTotal > cut ? beforeTotal - cut : 0;
    } else if (oldUserLp < newUserLp) {
      SLISBNB_X.mint(holder, newUserLp - oldUserLp);
      userTotalBalance[account] += newUserLp - oldUserLp;
    }
    // update user slisBNBx balance as new LP
    userModuleBal.userPart = newUserLp;

    emit UserModuleRebalanced(account, _module, newUserLp, newReservedLp);

    return (true, newUserLp);
  }

  /**
   * @notice only module can call this function to sync delegatee for user
   * @param account user address to sync
   * @param newDelegatee new delegatee address
   */
  function syncDelegatee(address account, address newDelegatee) external {
    require(moduleConfig[msg.sender].moduleAddress == msg.sender, "unauthorized msg.sender");

    _delegateAllTo(account, newDelegatee);
  }

  /**
   * @dev delegate all slisBNBx to given address without rebalancing
   * @param newDelegatee new target address of collateral tokens
   */
  function delegateAllTo(address newDelegatee) external {
    _delegateAllTo(msg.sender, newDelegatee);
  }

  function _delegateAllTo(address account, address newDelegatee) internal {
    if (newDelegatee == delegation[account]) {
      return;
    }
    require(newDelegatee != address(0), "cannot delegate to zero address");
    // current delegatee
    address oldDelegatee = delegation[account];
    if (oldDelegatee == address(0)) {
      oldDelegatee = account;
    }
    // burn all slisBNBx from account or delegatee
    uint256 actualBurned = _safeBurnLp(oldDelegatee, userTotalBalance[account]);
    if (actualBurned != userTotalBalance[account]) {
      // adjust userTotalBalance if actual burned is less than expected
      userTotalBalance[account] = actualBurned;
    }
    // update delegatee record
    delegation[account] = newDelegatee;
    // mint all burned slisBNBx to new delegatee
    SLISBNB_X.mint(newDelegatee, actualBurned);

    emit ChangeDelegateTo(account, oldDelegatee, newDelegatee, actualBurned);
  }

  /* ----------------------- slisBNBx Re-balancing ----------------------- */
  /**
   * @dev sync user's slisBNBx balance to retain a consistent ratio with token balance
   * @param _account user address to sync
   */
  function syncUserModuleLp(address _account, address _module) external {
    bool rebalanced = _syncUserModuleLp(_account, _module);
    require(rebalanced, "already synced");
  }

  function _syncUserModuleLp(address _account, address _module) private returns (bool) {
    ModuleConfig memory config = moduleConfig[_module];
    require(config.moduleAddress == _module, "unauthorized module");

    (bool rebalanced, ) = _rebalanceUserLp(_account, _module);
    return rebalanced;
  }

  /**
   * @dev sync multiple user's slisBNBx balance to retain a consistent ratio with token balance
   * @param _accounts user address to sync
   */
  function bulkSyncUserModules(address[] calldata _accounts, address[] calldata _module) external {
    require(_accounts.length == _module.length, "accounts and modules length mismatch");

    for (uint256 i = 0; i < _accounts.length; i++) {
      _syncUserModuleLp(_accounts[i], _module[i]);
    }
  }

  /* ----------------------------------- MANAGER functions ----------------------------------- */
  /**
   * @dev Set the cap of the MPC wallet
   * @param idx - index of the MPC wallet
   * @param cap - new cap of the MPC wallet
   */
  function setMpcWalletCap(uint256 idx, uint256 cap) external onlyRole(MANAGER) {
    require(idx < mpcWallets.length, "Invalid index");
    require(cap != mpcWallets[idx].cap, "Same cap");
    // get the current wallet
    MPCWallet storage wallet = mpcWallets[idx];
    // save old cap
    uint256 oldCap = wallet.cap;
    // set the cap
    wallet.cap = cap;
    // if cap less than the balance
    // we need to burn the difference, and mint to other MPCs
    if (cap < wallet.balance) {
      uint256 toBurn = wallet.balance - cap;
      // burn slisBNBx from MPC
      SLISBNB_X.burn(wallet.walletAddress, toBurn);
      // deduct balance
      wallet.balance -= toBurn;
      // mint slisBNBx to the other MPCs
      _mintToMPCs(toBurn);
    }
    emit MpcWalletCapChanged(wallet.walletAddress, oldCap, cap);
  }

  /**
   * @dev Remove MPC wallet
   * @param idx - index of the MPC wallet
   */
  function removeMPCWallet(uint256 idx) external onlyRole(MANAGER) {
    require(idx < mpcWallets.length, "Invalid index");
    // get the current wallet
    MPCWallet storage wallet = mpcWallets[idx];
    // cache address
    address walletAddress = wallet.walletAddress;
    // check if the balance is 0
    require(wallet.balance == 0, "Balance not zero");
    // remove the wallet
    mpcWallets[idx] = mpcWallets[mpcWallets.length - 1];
    mpcWallets.pop();
    // emit event
    emit MpcWalletRemoved(walletAddress);
  }

  /**
   * @dev Add MPC wallet
   * @param walletAddress - address of the MPC wallet
   * @param cap - cap of the MPC wallet
   */
  function addMPCWallet(address walletAddress, uint256 cap) external onlyRole(MANAGER) {
    require(walletAddress != address(0), "zero address provided");
    require(cap > 0, "Invalid cap");
    // check if the wallet already exists
    for (uint256 i = 0; i < mpcWallets.length; ++i) {
      require(mpcWallets[i].walletAddress != walletAddress, "Wallet already exists");
    }
    // add the wallet
    mpcWallets.push(MPCWallet(walletAddress, 0, cap));
    // emit event
    emit MpcWalletAdded(walletAddress, cap);
  }

  /**
   * @dev Mint fee to MPC wallets
   *      mint the slisBNBx as the amount of totalToken increment
   *      first mint, last burn
   * @param amount - amount of slisBNBx to mint
   */
  function _mintToMPCs(uint256 amount) internal {
    uint256 leftToMint = amount;
    // loop through the MPC wallets
    for (uint256 i = 0; i < mpcWallets.length; ++i) {
      // mint completed
      if (leftToMint == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i];
      // get slisBNBx balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance <= wallet.cap) {
        uint256 toMint = balance + leftToMint > wallet.cap ? wallet.cap - balance : leftToMint;
        // mint slisBNBx to the wallet
        SLISBNB_X.mint(wallet.walletAddress, toMint);
        // add up balance
        wallet.balance += toMint;
        // deduct leftToMint
        leftToMint -= toMint;
      }
    }

    require(leftToMint == 0, ErrorsLib.EXCEED_MPC_CAP);
  }

  /**
   * @dev Burn slisBNBx from MPC wallets
   *      burn the slisBNBx as the amount of totalToken decrement
   *      burn from the last MPC wallet
   * @param amount - amount of slisBNBx to burn
   */
  function _burnFromMPCs(uint256 amount) internal {
    uint256 leftToBurn = amount;
    // loop through the MPC wallets
    for (uint256 i = mpcWallets.length; i > 0; i--) {
      // burn completed
      if (leftToBurn == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i - 1];
      // get slisBNBx balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance > 0) {
        uint256 toBurn = balance < leftToBurn ? balance : leftToBurn;
        // burn slisBNBx from MPC
        SLISBNB_X.burn(wallet.walletAddress, toBurn);
        // deduct balance
        wallet.balance -= toBurn;
        // deduct leftToMint
        leftToBurn -= toBurn;
      }
    }
  }

  /**
   * @dev Update module configurations; to disable a module, set discount to 100% and feeRate to 0
   * @param _modules The list of modules to be updated.
   * @param _configs The list of module configurations.
   */
  function updateModules(address[] calldata _modules, ModuleConfig[] calldata _configs) external onlyRole(MANAGER) {
    require(_modules.length == _configs.length, "modules and configs length mismatch");

    for (uint256 i = 0; i < _modules.length; i++) {
      address module = _modules[i];
      ModuleConfig memory config = _configs[i];
      require(module != address(0), "module is the zero address");
      require(config.feeRate <= DENOMINATOR, "userLpRate invalid");
      require(config.discount <= DENOMINATOR, "discount invalid");
      ModuleConfig memory _config = moduleConfig[module];
      require(config.moduleAddress == module, "module address should not change");
      require(_config.discount != config.discount || _config.feeRate != config.feeRate, "no changes detected");

      bool enabled = true;
      if (config.discount == DENOMINATOR) {
        // when disabling a module, set `discount` to 100% and `feeRate` to 0
        require(config.feeRate == 0, "feeRate must be 0 when disabling module");
        enabled = false;
      }

      moduleConfig[module] = config;
      emit ModuleConfigUpdated(module, config.discount, config.feeRate, enabled);
    }
  }

  /**
   * @dev only admin can upgrade the contract
   * @param _newImplementation new implementation address
   */
  function _authorizeUpgrade(address _newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

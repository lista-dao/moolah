// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMoolah, MarketParams, Id, Position } from "./interfaces/IMoolah.sol";
import { ILpToken } from "./interfaces/ILpToken.sol";
import { MarketParamsLib } from "./libraries/MarketParamsLib.sol";
import {Moolah} from "./Moolah.sol";
import {IStakeManager} from "../oracle/interfaces/IStakeManager.sol";

contract SlisBNBProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;

  struct MPCWallet {
    address walletAddress;
    uint256 balance;
    uint256 cap;
  }

  // slisBNB token address
  address public immutable token;
  // Moolah contract address
  IMoolah public immutable MOOLAH;
  // StakeManager contract address
  IStakeManager public immutable stakeManager;
  // User will get this LP token as proof of staking ERC20-LP, e.g clisXXX
  ILpToken public immutable lpToken;
  // delegatee fully holds user's lpToken, NO PARTIAL delegation
  // account > delegatee
  mapping(address => address) public delegation;
  // user account > market id > amount of token deposited
  mapping(address => mapping(Id => uint256)) public userMarketDeposit;
  // user account > total amount of token deposited
  mapping(address => uint256) public userTotalDeposit;
  // user account > total amount of lpToken minted to user
  mapping(address => uint256) public userLp;
  // rate of lpToken to user when deposit
  uint128 public userLpRate;
  // user account > sum reserved lpToken
  mapping(address => uint256) public userReservedLp;
  // total reserved lpToken
  uint256 public totalReservedLp;
  // mpc wallets
  MPCWallet[] public mpcWallets;

  uint128 public constant RATE_DENOMINATOR = 1e18;
  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role

  /* ------------------ Events ------------------ */
  event UserLpRebalanced(address account, uint256 userLp, uint256 reservedLp);
  event UserLpRateChanged(uint128 rate);
  event Deposit(address indexed account, uint256 amount, uint256 lPAmount);
  event Withdrawal(address indexed owner, uint256 amount);
  event ChangeDelegateTo(address account, address oldDelegatee, address newDelegatee);
  event MpcWalletCapChanged(address wallet, uint256 oldCap, uint256 newCap);
  event MpcWalletRemoved(address wallet);
  event MpcWalletAdded(address wallet, uint256 cap);


  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  /// @param _token The address of the token contract.
  /// @param _stakeManager The address of the StakeManager contract.
  /// @param _lpToken The address of the LP token contract.
  constructor(
    address moolah,
    address _token,
    address _stakeManager,
    address _lpToken
  ) {
    require(moolah != address(0), "moolah is the zero address");
    require(_token != address(0), "token is the zero address");
    require(_stakeManager != address(0), "stakeManager is the zero address");
    require(_lpToken != address(0), "lpToken is the zero address");

    MOOLAH = IMoolah(moolah);
    token = _token;
    stakeManager = IStakeManager(_stakeManager);
    lpToken = ILpToken(_lpToken);
  }


  /// @dev Initializes the contract with the given parameters.
  /// @param admin The new admin of the contract.
  /// @param manager The new manager of the contract.
  /// @param _userLpRate The rate of LP token to user when deposit.
  function initialize(
      address admin,
      address manager,
      uint128 _userLpRate
  ) public initializer {
    require(admin != address(0), "admin is the zero address");
    require(manager != address(0), "manager is the zero address");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);

    userLpRate = _userLpRate;
  }

  /// @dev Supply collateral to the Moolah contract. And mint lpToken to user
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    bytes calldata data
  ) external {
    require(assets > 0, "zero supply amount");
    require(marketParams.collateralToken == token, "invalid collateral token");

    // transfer token from user to this contract
    IERC20(token).safeTransferFrom(msg.sender, address(this), assets);

    // supply to Moolah
    IERC20(token).safeIncreaseAllowance(address(MOOLAH), assets);
    MOOLAH.supplyCollateral(marketParams, assets, onBehalf, data);

    // rebalance user's lpToken
    (,uint256 latestLpBalance) = _syncPosition(marketParams.id(), onBehalf);

    emit Deposit(onBehalf, assets, latestLpBalance);
  }


  /// @dev Withdraws the specified amount of collateral from the Moolah contract. And rebalance lpToken
  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
  ) external {
    require(assets > 0, "zero withdrawal amount");
    require(_isSenderAuthorized(onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == token, "invalid collateral token");

    // withdraw from distributor
    MOOLAH.withdrawCollateral(marketParams, assets, onBehalf, address(this));
    // rebalance user's lpToken
    _syncPosition(marketParams.id(), onBehalf);

    // transfer token to user
    IERC20(token).safeTransfer(receiver, assets);
    emit Withdrawal(onBehalf, assets);
  }

  /// @dev Will be called when liquidation happens
  /// @param id The market id.
  /// @param borrower The address of the borrower.
  function liquidate(Id id, address borrower) external {
    require(msg.sender == address(MOOLAH), "only moolah can call this function");
    _syncPosition(id, borrower);
  }

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
    return msg.sender == onBehalf || MOOLAH.isAuthorized(onBehalf, msg.sender);
  }

  /**
   * @notice User's available lpToken might lower than the burn amount
     *         due to the change of exchangeRate, ReservedLpRate or the value of the LP token fluctuates from time to time
     *         i.e. userLp[account] might < lpToken.balanceOf(holder)
     * @param holder lp token holder
     * @param amount amount to burn
     */
  function _safeBurnLp(address holder, uint256 amount) internal {
    uint256 availableBalance = lpToken.balanceOf(holder);
    if (amount <= availableBalance) {
      lpToken.burn(holder, amount);
    } else if (availableBalance > 0) {
      // existing users do not have enough lpToken
      lpToken.burn(holder, availableBalance);
    }
  }

  /**
   * @dev mint/burn lpToken to sync user's lpToken with token balance
     * @param account user address to sync
     */
  function _rebalanceUserLp(address account) internal returns (bool, uint256) {
    uint256 userTotalDepositAmount = userTotalDeposit[account];

    // ---- [1] Estimated LP value
    // Total LP(User + Reserve)
    uint256 newTotalLp = stakeManager.convertSnBnbToBnb(userTotalDepositAmount);
    // User's LP
    uint256 newUserLp = newTotalLp * userLpRate / RATE_DENOMINATOR;
    // Reserve's LP
    uint256 newReservedLp = newTotalLp - newUserLp;

    // ---- [2] Current user LP and reserved LP
    uint256 oldUserLp = userLp[account];
    uint256 oldReservedLp = userReservedLp[account];

    // LP balance unchanged
    if (oldUserLp == newUserLp && oldReservedLp == newReservedLp) {
      return (false, oldUserLp);
    }

    // ---- [3] handle reserved LP
    if (oldReservedLp > newReservedLp) {
      _burnFromMPCs(oldReservedLp - newReservedLp);
      totalReservedLp -= (oldReservedLp - newReservedLp);
    } else if (oldReservedLp < newReservedLp) {
      _mintToMPCs(newReservedLp - oldReservedLp);
      totalReservedLp += (newReservedLp - oldReservedLp);
    }
    userReservedLp[account] = newReservedLp;

    // ---- [4] handle user LP and delegation
    address holder = delegation[account];
    // account as the default delegatee if holder is not set
    if(holder == address(0)) {
      holder = account;
      delegation[account] = holder;
    }
    if (oldUserLp > newUserLp) {
      _safeBurnLp(holder, oldUserLp - newUserLp);
    } else if (oldUserLp < newUserLp) {
      lpToken.mint(holder, newUserLp - oldUserLp);
    }
    // update user LP balance as new LP
    userLp[account] = newUserLp;

    emit UserLpRebalanced(account, newUserLp, newReservedLp);

    return (true, newUserLp);
  }

  function _syncPosition(Id id, address account) internal returns (bool, uint256) {
    require(MOOLAH.idToMarketParams(id).collateralToken == token && MOOLAH.providers(id) == address(this), "invalid market");
    uint256 userMarketSupplyCollateral = MOOLAH.position(id, account).collateral;
    if (userMarketSupplyCollateral >= userMarketDeposit[account][id]) {
      uint256 depositAmount = userMarketSupplyCollateral - userMarketDeposit[account][id];
      userTotalDeposit[account] += depositAmount;
    } else {
      uint256 withdrawAmount = userMarketDeposit[account][id] - userMarketSupplyCollateral;
      userTotalDeposit[account] -= withdrawAmount;
    }
    userMarketDeposit[account][id] = userMarketSupplyCollateral;

    return _rebalanceUserLp(account);
  }

  /**
  * delegate all collateral tokens to given address
  * @param newDelegatee new target address of collateral tokens
    */
  function delegateAllTo(address newDelegatee)
  external
  {
    require(
      newDelegatee != address(0) &&
      newDelegatee != delegation[msg.sender],
      "newDelegatee cannot be zero address or same as current delegatee"
    );
    // current delegatee
    address oldDelegatee = delegation[msg.sender];
    // burn all lpToken from account or delegatee
    _safeBurnLp(oldDelegatee, userLp[msg.sender]);
    // update delegatee record
    delegation[msg.sender] = newDelegatee;
    // clear user's lpToken record
    userLp[msg.sender] = 0;
    // rebalance user's lpToken
    _rebalanceUserLp(msg.sender);

    emit ChangeDelegateTo(msg.sender, oldDelegatee, newDelegatee);
  }

  /* ----------------------- Lp Token Re-balancing ----------------------- */
  /**
  * @dev sync user's lpToken balance to retain a consistent ratio with token balance
    * @param _account user address to sync
    */
  function syncUserLp(Id id, address _account) external {
    (bool rebalanced,) = _syncPosition(id, _account);
    require(rebalanced, "already synced");
  }

  /**
  * @dev sync multiple user's lpToken balance to retain a consistent ratio with token balance
    * @param _accounts user address to sync
    */
  function bulkSyncUserLp(Id[] calldata ids, address[] calldata _accounts) external {
    for (uint256 i = 0; i < _accounts.length; i++) {
      for (uint256 j = 0; j < ids.length; j++) {
        // sync user's lpToken balance
        _syncPosition(ids[j], _accounts[i]);
      }
    }
  }

  /* ----------------------------------- MANAGER functions ----------------------------------- */
  function setUserLpRate(uint128 _userLpRate) external onlyRole(MANAGER) {
    require(_userLpRate <= 1e18, "userLpRate invalid");

    userLpRate = _userLpRate;
    emit UserLpRateChanged(userLpRate);
  }
  /**
 * @dev Set the cap of the MPC wallet
   * @param idx - index of the MPC wallet
   * @param cap - new cap of the MPC wallet
   */
  function setMpcWalletCap(uint256 idx, uint256 cap) external onlyRole(MANAGER) {
    require(idx < mpcWallets.length, "Invalid index");
    require(cap > 0 && cap != mpcWallets[idx].cap, "Invalid cap");
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
      // burn lpToken from MPC
      lpToken.burn(wallet.walletAddress, toBurn);
      // deduct balance
      wallet.balance -= toBurn;
      // mint lpToken to the other MPCs
      _mintToMPCs(toBurn);
    }
    // emit event
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
   * @dev Mint lpToken to MPC wallets
   *      mint the lpToken as the amount of totalToken increment
   *      first mint, last burn
   * @param amount - amount of lpToken to mint
   */
  function _mintToMPCs(uint256 amount) internal {
    uint256 leftToMint = amount;
    // loop through the MPC wallets
    for (uint256 i = 0; i < mpcWallets.length; ++i) {
      // mint completed
      if (leftToMint == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i];
      // get lpToken balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance <= wallet.cap) {
        uint256 toMint = balance + leftToMint > wallet.cap ? wallet.cap - balance : leftToMint;
        // mint lpToken to the wallet
        lpToken.mint(wallet.walletAddress, toMint);
        // add up balance
        wallet.balance += toMint;
        // deduct leftToMint
        leftToMint -= toMint;
      }
    }

    require(leftToMint == 0, "Not enough MPC wallets to mint");
  }

  /**
   * @dev Burn lpToken from MPC wallets
   *      burn the lpToken as the amount of totalToken decrement
   *      burn from the last MPC wallet
   * @param amount - amount of lpToken to burn
   */
  function _burnFromMPCs(uint256 amount) internal {
    uint256 leftToBurn = amount;
    // loop through the MPC wallets
    for (uint256 i = mpcWallets.length; i > 0; i--) {
      // burn completed
      if (leftToBurn == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i - 1];
      // get lpToken balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance > 0) {
        uint256 toBurn = balance < leftToBurn ? balance : leftToBurn;
        // burn lpToken from MPC
        lpToken.burn(wallet.walletAddress, toBurn);
        // deduct balance
        wallet.balance -= toBurn;
        // deduct leftToMint
        leftToBurn -= toBurn;
      }
    }
  }

  /**
   * @dev only admin can upgrade the contract
     * @param _newImplementation new implementation address
     */
  function _authorizeUpgrade(address _newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

}

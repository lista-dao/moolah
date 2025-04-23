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

contract MoolahSlisBNBProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;

  // slisBNB token address
  address public token;
  // Moolah contract address
  IMoolah public MOOLAH;
  // StakeManager contract address
  IStakeManager public stakeManager;
  // User will get this LP token as proof of staking ERC20-LP, e.g clisXXX
  ILpToken public lpToken;
  // delegatee fully holds user's lpToken, NO PARTIAL delegation
  // account > delegatee
  mapping(address => address) public delegation;
  // user account > market id > amount of token deposited
  mapping(address => mapping(Id => uint256)) public userMarketDeposit;
  // user account > total amount of token deposited
  mapping(address => uint256) public userTotalDeposit;
  // user account > total amount of lpToken minted to user
  mapping(address => uint256) public userLp;
  // token to lpToken exchange rate
  uint128 public exchangeRate;
  // rate of lpToken to user when deposit
  uint128 public userLpRate;
  // should be a mpc wallet address
  address public lpReserveAddress;
  // user account > sum reserved lpToken
  mapping(address => uint256) public userReservedLp;
  // total reserved lpToken
  uint256 public totalReservedLp;

  uint128 public constant RATE_DENOMINATOR = 1e18;
  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role

  /* ------------------ Events ------------------ */
  event UserLpRebalanced(address account, uint256 userLp, uint256 reservedLp);
  event ExchangeRateChanged(uint128 rate);
  event UserLpRateChanged(uint128 rate);
  event LpReserveAddressChanged(address newAddress);
  event Deposit(address indexed account, uint256 amount, uint256 lPAmount);
  event Withdrawal(address indexed owner, uint256 amount);
  event ChangeDelegateTo(address account, address oldDelegatee, address newDelegatee);


  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }


  /// @dev Initializes the contract with the given parameters.
  /// @param admin The new admin of the contract.
  /// @param manager The new manager of the contract.
  /// @param moolah The address of the Moolah contract.
  /// @param _token The address of the token contract.
  /// @param _stakeManager The address of the StakeManager contract.
  /// @param _lpToken The address of the LP token contract.
  /// @param _userLpRate The rate of LP token to user when deposit.
  /// @param _lpReserveAddress The address of the LP reserve.
  function initialize(
      address admin,
      address manager,
      address moolah,
      address _token,
      address _stakeManager,
      address _lpToken,
      uint128 _userLpRate,
      address _lpReserveAddress
  ) public initializer {
    require(admin != address(0), "admin is the zero address");
    require(manager != address(0), "manager is the zero address");
    require(moolah != address(0), "moolah is the zero address");
    require(_token != address(0), "token is the zero address");
    require(_stakeManager != address(0), "stakeManager is the zero address");
    require(_lpToken != address(0), "lpToken is the zero address");
    require(_lpReserveAddress != address(0), "lpReserveAddress is the zero address");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);

    MOOLAH = IMoolah(moolah);
    token = _token;
    stakeManager = IStakeManager(_stakeManager);
    lpToken = ILpToken(_lpToken);
    userLpRate = _userLpRate;
    lpReserveAddress = _lpReserveAddress;
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


    // get current delegatee
    address oldDelegatee = delegation[onBehalf];
    // burn all lpToken from old delegatee
    if (oldDelegatee != onBehalf && oldDelegatee != address(0)) {
      _safeBurnLp(oldDelegatee, userLp[onBehalf]);
      // clear user's lpToken record
      userLp[onBehalf] = 0;
    }
    // update delegatee
    delegation[onBehalf] = onBehalf;

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
    _syncPosition(marketParams.id(), msg.sender);

    // transfer token to user
    IERC20(token).safeTransfer(receiver, assets);
    emit Withdrawal(msg.sender, assets);
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
      _safeBurnLp(lpReserveAddress, oldReservedLp - newReservedLp);
      totalReservedLp -= (oldReservedLp - newReservedLp);
    } else if (oldReservedLp < newReservedLp) {
      lpToken.mint(lpReserveAddress, newReservedLp - oldReservedLp);
      totalReservedLp += (newReservedLp - oldReservedLp);
    }
    userReservedLp[account] = newReservedLp;

    // ---- [4] handle user LP and delegation
    address holder = delegation[account];
    // account as the default delegatee if holder is not set
    if(holder == address(0)) {
      holder = account;
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

  /* ----------------------------------- Admin functions ----------------------------------- */
  function setUserLpRate(uint128 _userLpRate) external onlyRole(MANAGER) {
    require(_userLpRate <= 1e18 && _userLpRate <= exchangeRate, "userLpRate invalid");

    userLpRate = _userLpRate;
    emit UserLpRateChanged(userLpRate);
  }

  /**
   * change lpReserveAddress, all reserved lpToken will be burned from original address and be minted to new address
   * @param _lpTokenReserveAddress new lpTokenReserveAddress
     */
  function setLpReserveAddress(address _lpTokenReserveAddress) external onlyRole(MANAGER) {
    require(_lpTokenReserveAddress != address(0) && _lpTokenReserveAddress != lpReserveAddress, "lpTokenReserveAddress invalid");
    if (totalReservedLp > 0) {
      lpToken.burn(lpReserveAddress, totalReservedLp);
      lpToken.mint(_lpTokenReserveAddress, totalReservedLp);
    }
    lpReserveAddress = _lpTokenReserveAddress;
    emit LpReserveAddressChanged(lpReserveAddress);
  }

  /**
   * @dev only admin can upgrade the contract
     * @param _newImplementation new implementation address
     */
  function _authorizeUpgrade(address _newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

}

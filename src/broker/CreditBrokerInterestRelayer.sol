// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { ICreditBrokerBase } from "./interfaces/ICreditBroker.sol";
import { ICreditBrokerInterestRelayer } from "./interfaces/ICreditBrokerInterestRelayer.sol";

/// @title Credit Broker Interest Relayer
/// @author Lista DAO
/// @notice This contract act as a relayer between CreditBrokers and Moolah vaults
///         Brokers can transfer interest to this contract, or provide LISTA and then transfer loan to itself;
///         this contract will supply to the Moolah vault when the accumulated amount exceeds minLoan
contract CreditBrokerInterestRelayer is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardTransientUpgradeable,
  ICreditBrokerInterestRelayer
{
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  // ------- Roles -------
  bytes32 public constant MANAGER = keccak256("MANAGER");

  // ------- State variables -------
  /// @dev Moolah contract
  IMoolah public MOOLAH;
  /// @dev vault address
  address public vault;
  /// @dev liquidation whitelist
  EnumerableSet.AddressSet private brokers;
  /// @dev vault token
  address public token;
  /// @dev LISTA token address
  address public listaToken;
  /// @dev the amount of loan should be supplied to Moolah vault
  uint256 public supplyAmount;

  // ------- Modifiers -------
  modifier onlyBroker() {
    require(brokers.contains(msg.sender), "relayer/not-broker");
    _;
  }

  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initialize the LendingBroker contract
   * @param _admin The address of the admin
   * @param _manager The address of the manager
   * @param _moolah The address of the Moolah contract
   * @param _vault The address of the Moolah vault
   * @param _token The address of the vault token
   * @param _listaToken The address of the LISTA token
   */
  function initialize(
    address _admin,
    address _manager,
    address _moolah,
    address _vault,
    address _token,
    address _listaToken
  ) public initializer {
    require(
      _admin != address(0) &&
        _manager != address(0) &&
        _moolah != address(0) &&
        _vault != address(0) &&
        _token != address(0) &&
        _listaToken != address(0),
      "relayer/zero-address-provided"
    );

    __AccessControlEnumerable_init_unchained();
    __ReentrancyGuardTransient_init_unchained();
    // grant roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);

    MOOLAH = IMoolah(_moolah);
    vault = _vault;
    token = _token;
    listaToken = _listaToken;
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Broker transfers interest amount to this contract,
   *      and this contract supplies to Moolah vault if the balance exceeds minLoan
   * @param amount The amount of interest to supply
   */
  function supplyToVault(uint256 amount) external override nonReentrant onlyBroker {
    // transfer interest from broker
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    supplyAmount += amount;

    // get minLoan
    uint256 minLoan = MOOLAH.minLoan(MOOLAH.idToMarketParams(ICreditBrokerBase(msg.sender).MARKET_ID()));

    // records interest accumulated event
    emit InterestAccumulated(msg.sender, supplyAmount);

    // supply to moolah vault if accumulated amount exceeds minLoan
    if (supplyAmount >= minLoan) {
      uint256 _supplyToVault = supplyAmount;
      supplyAmount = 0;
      // approve to moolah
      IERC20(token).safeIncreaseAllowance(address(MOOLAH), _supplyToVault);
      // supply to moolah vault
      MOOLAH.supply(MOOLAH.idToMarketParams(ICreditBrokerBase(msg.sender).MARKET_ID()), _supplyToVault, 0, vault, "");
      // records supplied to vault event
      emit SuppliedToMoolahVault(_supplyToVault);
    }
  }

  /**
   * @dev Broker transfers loan amount from Relayer to itself; due to repaying interest in LISTA
   * @param amount The amount of loan to transfer
   */
  function transferLoan(uint256 amount) external override nonReentrant onlyBroker {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 remainingLoan = balance - supplyAmount;
    require(amount <= remainingLoan, "relayer/insufficient-loan-balance");

    IERC20(token).safeTransfer(msg.sender, amount);

    emit TransferredLoan(msg.sender, amount, remainingLoan, msg.sender);
  }

  /**
   * @dev Returns the list of whitelisted brokers
   * @return brokerList The list of whitelisted brokers
   */
  function getBrokers() external view returns (address[] memory) {
    uint256 length = brokers.length();
    address[] memory brokerList = new address[](length);
    for (uint256 i = 0; i < length; i++) {
      brokerList[i] = brokers.at(i);
    }
    return brokerList;
  }

  ///////////////////////////////////////
  /////        Admin functions      /////
  ///////////////////////////////////////

  /**
   * @dev Adds a broker to the whitelist
   * @param broker The address of the broker to add
   */
  function addBroker(address broker) public onlyRole(MANAGER) {
    require(!brokers.contains(broker), "broker/same-value-provided");
    require(ICreditBrokerBase(broker).LOAN_TOKEN() == token, "relayer/invalid-loan-token");
    brokers.add(broker);
    emit AddedBroker(broker);
  }

  /**
   * @dev Removes a broker from the whitelist
   * @param broker The address of the broker to remove
   */
  function removeBroker(address broker) public onlyRole(MANAGER) {
    require(brokers.contains(broker), "broker/same-value-provided");
    brokers.remove(broker);
    emit RemovedBroker(broker);
  }

  /**
   * @dev Withdraw deposited loan from the relayer to a specified receiver; only callable by MANAGER
   * @param amount The amount of loan to withdraw
   * @param receiver The address of the receiver
   */
  function withdrawLoan(uint256 amount, address receiver) external override nonReentrant onlyRole(MANAGER) {
    require(receiver != address(0), "relayer/zero-address-provided");
    require(amount > 0, "relayer/zero-amount-provided");

    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 remainingLoan = balance - supplyAmount;
    require(amount <= remainingLoan, "relayer/insufficient-loan-balance");

    IERC20(token).safeTransfer(receiver, amount);

    emit TransferredLoan(msg.sender, amount, remainingLoan, receiver);
  }

  /**
   * @dev withdraw LISTA tokens by manager
   */
  function withdrawLista(uint256 amount, address receiver) external override nonReentrant onlyRole(MANAGER) {
    require(receiver != address(0), "relayer/zero-address-provided");
    require(amount > 0, "relayer/zero-amount-provided");

    IERC20(listaToken).safeTransfer(receiver, amount);

    emit WithdrawnLista(listaToken, amount, receiver);
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

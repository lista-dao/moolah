// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { IBrokerBase } from "./interfaces/IBroker.sol";
import { IBrokerInterestRelayer } from "./interfaces/IBrokerInterestRelayer.sol";

/// @title Broker Interest Relayer
/// @author Lista DAO
/// @notice This contract act as a relayer between LendingBrokers and Moolah vaults
///         Brokers can transfer interest to this contract,
///         and this contract will supply to the Moolah vault when the balance exceeds Moolah's minLoan requirement
contract BrokerInterestRelayer is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  IBrokerInterestRelayer
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

  // ------- Modifiers -------
  modifier onlyBroker() {
    require(brokers.contains(msg.sender), "relayer/not-broker");
    _;
  }

  /**
   * @dev Initialize the LendingBroker contract
   * @param _admin The address of the admin
   * @param _manager The address of the manager
   * @param _moolah The address of the Moolah contract
   * @param _vault The address of the Moolah vault
   * @param _token The address of the vault token
   */
  function initialize(
    address _admin,
    address _manager,
    address _moolah,
    address _vault,
    address _token
  ) public initializer {
    require(
      _admin != address(0) &&
        _manager != address(0) &&
        _moolah != address(0) &&
        _vault != address(0) &&
        _token != address(0),
      "relayer/zero-address-provided"
    );

    __AccessControlEnumerable_init();
    __ReentrancyGuard_init();
    // grant roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);

    MOOLAH = IMoolah(_moolah);
    vault = _vault;
    token = _token;
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

    // get minLoan
    uint256 minLoan = MOOLAH.minLoan(MOOLAH.idToMarketParams(IBrokerBase(msg.sender).MARKET_ID()));

    // supply to moolah vault if the balance exceeds minLoan
    // ignore the supply info of the vault after supplying,
    // otherwise, keep the balance in this contract
    uint256 balance = IERC20(token).balanceOf(address(this));
    // records interest accumulated event
    emit InterestAccumulated(msg.sender, balance);

    if (balance >= minLoan) {
      // approve to moolah
      IERC20(token).safeIncreaseAllowance(address(MOOLAH), balance);
      // supply to moolah vault
      MOOLAH.supply(MOOLAH.idToMarketParams(IBrokerBase(msg.sender).MARKET_ID()), balance, 0, vault, "");
      // records supplied to vault event
      emit SuppliedToMoolahVault(balance);
    }
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
    require(IBrokerBase(broker).LOAN_TOKEN() == token, "relayer/invalid-loan-token");
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

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

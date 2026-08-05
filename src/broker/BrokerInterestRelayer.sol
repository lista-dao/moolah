// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { IBrokerBase } from "./interfaces/IBroker.sol";
import { IBrokerInterestRelayer } from "./interfaces/IBrokerInterestRelayer.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { IBrokerInterestLockBuffer } from "../utils/interfaces/IBrokerInterestLockBuffer.sol";

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

  // ------- Constants -------
  /// @dev WAD scaling for the fee rate (1e18 == 100%), matching Moolah's market fee semantics
  uint256 public constant WAD = 1e18;
  /// @dev maximum protocol fee rate (25%), mirroring Moolah's MAX_FEE
  uint256 public constant MAX_FEE = 0.25e18;
  /// @dev default protocol fee rate (10%) applied by initializeV2
  uint256 public constant DEFAULT_FEE_RATE = 0.1e18;

  // ------- State variables -------
  /// @dev Moolah contract
  IMoolah public MOOLAH;
  /// @dev vault address
  address public vault;
  /// @dev liquidation whitelist
  EnumerableSet.AddressSet private brokers;
  /// @dev vault token
  address public token;

  // --- V2 storage (appended to preserve layout) ---
  /// @dev protocol fee rate charged on broker revenue (interest + penalty), WAD-scaled
  uint256 public feeRate;
  /// @dev recipient of the protocol fee
  address public feeRecipient;

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

  /**
   * @dev V2 reinitializer: enable the protocol fee on broker revenue at the default 10% rate.
   *      Must be called atomically via `upgradeToAndCall` by the DEFAULT_ADMIN_ROLE (timelock),
   *      so the config is set in the same tx the new implementation is wired in.
   *      The rate can be changed afterwards via `setFeeRate` (MANAGER).
   * @param _feeRecipient The recipient of the protocol fee
   */
  function initializeV2(address _feeRecipient) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_feeRecipient != address(0), "relayer/zero-address-provided");

    feeRate = DEFAULT_FEE_RATE;
    feeRecipient = _feeRecipient;

    emit SetFeeRate(0, DEFAULT_FEE_RATE);
    emit SetFeeRecipient(address(0), _feeRecipient);
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

    // skim the protocol fee on incoming revenue (interest + penalty) before it accrues to the vault.
    // Fee is floored so rounding dust stays with the vault (suppliers), never the fee recipient.
    uint256 fee = Math.mulDiv(amount, feeRate, WAD, Math.Rounding.Floor);
    if (fee > 0 && feeRecipient != address(0)) {
      IERC20(token).safeTransfer(feeRecipient, fee);
      emit ProtocolFeeCharged(msg.sender, feeRecipient, fee);
    }

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
      // audit #08: atomic notify so totalAssets smooths the flush; no-op when vault has no buffer set.
      address buf = IMoolahVault(vault).lockBuffer();
      if (buf != address(0)) IBrokerInterestLockBuffer(buf).notifyBrokerInterest(balance);
      // records supplied to vault event
      emit SuppliedToMoolahVault(balance);
    }
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

  /**
   * @dev Set the protocol fee rate charged on broker revenue (interest + penalty)
   * @param _feeRate The new fee rate, WAD-scaled (1e18 == 100%)
   */
  function setFeeRate(uint256 _feeRate) external override onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE, "relayer/max-fee-exceeded");
    require(_feeRate != feeRate, "broker/same-value-provided");
    emit SetFeeRate(feeRate, _feeRate);
    feeRate = _feeRate;
  }

  /**
   * @dev Set the recipient of the protocol fee
   * @param _feeRecipient The new fee recipient
   */
  function setFeeRecipient(address _feeRecipient) external override onlyRole(MANAGER) {
    require(_feeRecipient != address(0), "relayer/zero-address-provided");
    require(_feeRecipient != feeRecipient, "broker/same-value-provided");
    emit SetFeeRecipient(feeRecipient, _feeRecipient);
    feeRecipient = _feeRecipient;
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

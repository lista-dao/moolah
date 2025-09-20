pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IRateCalculator, RateConfig } from "./interfaces/IRateCalculator.sol";
import { BrokerMath, RATE_SCALE } from "./libraries/BrokerMath.sol";

/// @title RateCalculator
/// @author Lista DAO
/// @notice This contract calculates and update the latest rate for LendingBrokers
contract RateCalculator is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IRateCalculator {

  // ------- Roles -------
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");

  // ------- State variables -------

  // broker address => rate config
  mapping(address => RateConfig) brokers;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializes the contract with the given addresses
   * @param _admin The address of the admin role
   * @param _manager The address of the manager role
   * @param _pauser The address of the pauser role
   * @param _bot The address of the bot role
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot
  ) public initializer {
    require(
      _admin != address(0) &&
      _manager != address(0) &&
      _pauser != address(0) &&
      _bot != address(0),
      "RateCalculator/zero-address-provided"
    );

    __AccessControl_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);
  }

  ///////////////////////////////////////
  /////     External functions      /////
  ///////////////////////////////////////

  /**
   * @dev Returns the current interest rate for the caller's broker
   *      If time has not elapsed since the last update, return the current rate
   *      otherwise, calculate the new rate based on the elapsed time
   */
  function accrueRate(address broker) external override returns (uint256) {
    return _accrueRate(broker);
  }

  /**
   * @dev Returns the current interest rate for the caller's broker
   */
  function getRate(address broker) external view override returns (uint256) {
    RateConfig memory config = brokers[broker];
    require(brokers[broker].lastUpdated != 0, "RateCalculator/broker-not-active");
    uint256 ratePerSecond = config.ratePerSecond;
    uint256 lastUpdated = config.lastUpdated;
    uint256 currentRate = config.currentRate;
    // no rate set, return default
    if (ratePerSecond == 0) {
      return RATE_SCALE;
    }
    // no time elapsed, return current rate
    if (lastUpdated == block.timestamp) {
      return currentRate;
    }
    return uint256(BrokerMath._rmul(BrokerMath._rpow(ratePerSecond, block.timestamp - lastUpdated, RATE_SCALE), currentRate));
  }

  /**
   * @dev Sets the interest rate per second for a batch of brokers
   * @param _brokers The addresses of the brokers
   * @param _ratePerSeconds The interest rates per second
   */
  function batchSetRatePerSecond(address[] calldata _brokers, uint256[] calldata _ratePerSeconds) external onlyRole(BOT) {
    require(_brokers.length > 0, "RateCalculator/empty-input");
    require(_brokers.length == _ratePerSeconds.length, "RateCalculator/length-mismatch");
    for (uint256 i = 0; i < _brokers.length; i++) {
      _setRatePerSecond(_brokers[i], _ratePerSeconds[i]);
    }
  }

  /**
   * @dev Sets the interest rate per second for a broker
   * @param _broker The address of the broker
   * @param _ratePerSecond The interest rate per second
   */
  function setRatePerSecond(address _broker, uint256 _ratePerSecond) external onlyRole(BOT) {
    return _setRatePerSecond(_broker, _ratePerSecond);
  }

  ///////////////////////////////////////
  /////     Internal functions      /////
  ///////////////////////////////////////

  /**
   * @dev Sets the interest rate per second for a broker
   * @param _broker The address of the broker
   * @param _ratePerSecond The interest rate per second
   */
  function _setRatePerSecond(address _broker, uint256 _ratePerSecond) internal {
    require(brokers[_broker].lastUpdated != 0, "RateCalculator/broker-not-active");
    require(
      _ratePerSecond <= brokers[_broker].maxRatePerSecond,
      "RateCalculator/rate-exceeds-max"
    );
    // accrue the rate first before overwriting it to avoid retroactive jumps
    _accrueRate(_broker);
    // update rate per second
    uint256 oldRate = brokers[_broker].ratePerSecond;
    brokers[_broker].ratePerSecond = _ratePerSecond;
    emit RatePerSecondUpdated(_broker, oldRate, _ratePerSecond);
  }

  /**
   * @dev Returns the current interest rate for the caller's broker
   *      If time has not elapsed since the last update, return the current rate
   *      otherwise, calculate the new rate based on the elapsed time
   */
  function _accrueRate(address broker) internal returns (uint256) {
    RateConfig storage config = brokers[broker];
    require(config.lastUpdated != 0, "RateCalculator/broker-not-active");
    uint256 ratePerSecond = config.ratePerSecond;
    uint256 lastUpdated = config.lastUpdated;
    uint256 currentRate = config.currentRate;
    // no rate set, return default
    if (ratePerSecond == 0) {
      config.lastUpdated = block.timestamp;
      return RATE_SCALE;
    }
    // no time elapsed, return current rate
    if (lastUpdated == block.timestamp) {
      return currentRate;
    }
    // update current rate
    config.currentRate = BrokerMath._rmul(BrokerMath._rpow(ratePerSecond, block.timestamp - lastUpdated, RATE_SCALE), currentRate);
    // refresh updated timestamp
    config.lastUpdated = block.timestamp;
    return config.currentRate;
  }

  ///////////////////////////////////////
  /////       Admin functions       /////
  ///////////////////////////////////////

  /**
   * @dev Sets the maximum interest rate per second for a broker
   * @param _broker The address of the broker
   * @param _maxRatePerSecond The maximum interest rate per second
   */
  function setMaxRatePerSecond(address _broker, uint256 _maxRatePerSecond) external onlyRole(MANAGER) {
    require(brokers[_broker].lastUpdated != 0, "RateCalculator/broker-not-active");
    uint256 oldRate = brokers[_broker].maxRatePerSecond;
    brokers[_broker].maxRatePerSecond = _maxRatePerSecond;
    emit MaxRatePerSecondSet(_broker, oldRate, _maxRatePerSecond);
  }

  /**
   * @dev Registers a new broker with the given parameters
   * @param _broker The address of the broker
   * @param _ratePerSecond The interest rate per second
   * @param _maxRatePerSecond The maximum interest rate per second
   */
  function registerBroker(address _broker, uint256 _ratePerSecond, uint256 _maxRatePerSecond) external onlyRole(MANAGER) {
    require(_broker != address(0), "RateCalculator/zero-address");
    require(brokers[_broker].lastUpdated == 0, "RateCalculator/broker-already-registered");
    require(_ratePerSecond > RATE_SCALE, "RateCalculator/rate-below-min");
    require(_maxRatePerSecond >= _ratePerSecond, "RateCalculator/max-rate-too-low");
    brokers[_broker] = RateConfig({
      currentRate: RATE_SCALE,
      ratePerSecond: _ratePerSecond,
      maxRatePerSecond: _maxRatePerSecond,
      lastUpdated: block.timestamp
    });
    emit BrokerRegistered(_broker, _ratePerSecond, _maxRatePerSecond);
  }

  /**
   * @dev Deregisters an existing broker
   * @param _broker The address of the broker
   */
  function deregisterBroker(address _broker) external onlyRole(MANAGER) {
    require(brokers[_broker].lastUpdated != 0, "RateCalculator/broker-not-active");
    delete brokers[_broker];
    emit BrokerDeregistered(_broker);
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct RateConfig {
  uint256 currentRate; // the current rate, scaled by 1e2
  uint256 ratePerSecond; // the fixed interest rate per second (update by bot)
  uint256 maxRatePerSecond; // the maximum allowed rate per second (update by manager)
  uint256 lastUpdated; // the last time the rate was updated
}

/// @dev RateCalculator Interface
interface IRateCalculator {

  /// ------------------------------
  ///      External functions
  /// ------------------------------
  /**
   * @dev Returns the current interest rate for the caller's broker
   *      If time has not elapsed since the last update, return the current rate
   *      otherwise, calculate the new rate based on the elapsed time
   */
  function accrueRate(address broker) external returns (uint256);

  /**
   * @dev Returns the current interest rate for the caller's broker
   */
  function getRate(address broker) external view returns (uint256);

  /// ------------------------------
  ///            Events
  /// ------------------------------
  event BrokerRegistered(address indexed broker, uint256 ratePerSecond, uint256 maxRatePerSecond);
  event BrokerDeregistered(address indexed broker);
  event RatePerSecondUpdated(address indexed broker, uint256 oldRate, uint256 newRate);
  event MaxRatePerSecondSet(address indexed broker, uint256 oldMaxRate, uint256 newMaxRate);
}

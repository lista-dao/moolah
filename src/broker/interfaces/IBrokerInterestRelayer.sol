// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Broker Interest Relayer Interface
interface IBrokerInterestRelayer {
  /**
   * @dev Broker transfers interest amount to this contract,
   *      and this contract supplies to Moolah vault if the balance exceeds minLoan
   * @param amount The amount of interest to supply
   */
  function supplyToVault(uint256 amount) external;

  /**
   * @dev Broker transfers loan amount from Relayer to itself; due to repaying interest in LISTA
   * @param amount The amount of loan to transfer
   */
  function transferLoan(uint256 amount) external;

  /// @dev ------- Events
  event AddedBroker(address indexed broker);
  event RemovedBroker(address indexed broker);
  event InterestAccumulated(address indexed broker, uint256 amount);
  event SuppliedToMoolahVault(uint256 amount);
}

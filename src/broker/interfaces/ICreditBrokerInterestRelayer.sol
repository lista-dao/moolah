// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Broker Interest Relayer Interface
interface ICreditBrokerInterestRelayer {
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

  function withdrawLoan(uint256 amount, address receiver) external;

  function withdrawLista(uint256 amount, address receiver) external;

  /// @dev ------- Events
  event AddedBroker(address indexed broker);
  event RemovedBroker(address indexed broker);
  event InterestAccumulated(address indexed broker, uint256 amount);
  event SuppliedToMoolahVault(uint256 amount);
  event TransferredLoan(address indexed caller, uint256 amount, uint256 remainingLoan, address receiver);
  event WithdrawnLista(address indexed token, uint256 amount, address receiver);
  event SetAllowTransferLoan(bool allow);
}

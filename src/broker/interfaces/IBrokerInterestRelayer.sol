// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "../../moolah/interfaces/IMoolah.sol";

/// @dev Broker Interest Relayer Interface
interface IBrokerInterestRelayer {
  /**
   * @dev Broker transfers interest amount to this contract,
   *      and this contract supplies to Moolah vault if the balance exceeds minLoan
   * @param amount The amount of interest to supply
   */
  function supplyToVault(uint256 amount) external;

  /**
   * @dev Set the protocol fee rate charged on broker revenue (interest + penalty).
   * @param _feeRate The new fee rate, WAD-scaled (1e18 == 100%)
   */
  function setFeeRate(uint256 _feeRate) external;

  /**
   * @dev Set the recipient of the protocol fee.
   * @param _feeRecipient The new fee recipient
   */
  function setFeeRecipient(address _feeRecipient) external;

  /**
   * @dev Whitelist a broker so it can forward interest to this relayer
   * @param broker The broker to register
   */
  function addBroker(address broker) external;

  /// @dev The registered brokers
  function getBrokers() external view returns (address[] memory);

  /// @dev ------- Events
  event AddedBroker(address indexed broker);
  event RemovedBroker(address indexed broker);
  event InterestAccumulated(address indexed broker, uint256 amount);
  event SuppliedToMoolahVault(uint256 amount);
  /// @dev relay kept in the relayer because the broker's market is not enabled in the vault or has a zero cap;
  ///      `amount` is this relay net of the protocol fee, `balance` is the relayer's total balance afterwards
  event SupplySkipped(address indexed broker, Id indexed marketId, uint256 amount, uint256 balance);
  /// @dev protocol fee skimmed from a broker's supplied revenue
  event ProtocolFeeCharged(address indexed broker, address indexed feeRecipient, uint256 fee);
  event SetFeeRate(uint256 oldFeeRate, uint256 newFeeRate);
  event SetFeeRecipient(address oldFeeRecipient, address newFeeRecipient);
}

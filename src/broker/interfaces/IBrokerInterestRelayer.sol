// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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

  /// @dev ------- Events
  event AddedBroker(address indexed broker);
  event RemovedBroker(address indexed broker);
  event InterestAccumulated(address indexed broker, uint256 amount);
  event SuppliedToMoolahVault(uint256 amount);
  /// @dev protocol fee skimmed from a broker's supplied revenue
  event ProtocolFeeCharged(address indexed broker, address indexed feeRecipient, uint256 fee);
  event SetFeeRate(uint256 oldFeeRate, uint256 newFeeRate);
  event SetFeeRecipient(address oldFeeRecipient, address newFeeRecipient);
}

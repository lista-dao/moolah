// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IBrokerInterestLockBuffer
/// @author Lista DAO
interface IBrokerInterestLockBuffer {
  function vault() external view returns (address);
  function asset() external view returns (address);
  function currentLocked() external view returns (uint256);
  function lockedAmount() external view returns (uint128);
  function lastUpdate() external view returns (uint64);
  function duration() external view returns (uint64);
  function notifyBrokerInterest(uint256 amount) external;
}

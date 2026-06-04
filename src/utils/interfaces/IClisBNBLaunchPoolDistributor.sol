// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IClisBNBLaunchPoolDistributor
/// @author Lista DAO
/// @notice Launchpool reward distributor (BSC: 0x81a62B329CC8939494d8613F614171a9955A46e8).
///         `claim` verifies a Merkle proof and sends `epoch.token` (address(0) => native BNB) to `_account`.
interface IClisBNBLaunchPoolDistributor {
  function claim(uint64 _epochId, address _account, uint256 _amount, bytes32[] calldata _proof) external;

  function claimed(uint64 _epochId, address _account) external view returns (bool);
}

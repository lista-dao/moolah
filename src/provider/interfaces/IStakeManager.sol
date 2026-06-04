// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IStakeManager {
  /// @notice Stakes native BNB and mints slisBNB to msg.sender.
  function deposit() external payable;

  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

  function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);
}

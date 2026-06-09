// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IStakeManager {
  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

  function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);

  /// @notice Stake native BNB and mint slisBNB to the caller.
  function deposit() external payable;

  /// @notice Instantly redeem slisBNB for native BNB (no unbonding cooldown), minus an
  ///         instant-withdraw fee. The caller must approve `_amountInSlisBnb` to this contract.
  /// @return bnbAmount The native BNB sent to the caller.
  function instantWithdraw(uint256 _amountInSlisBnb) external returns (uint256 bnbAmount);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBnbProviderCdp {
  /// @dev Withdraw BNB collateral from CDP strategy and transfer to recipient
  /// @notice use slisBnb strategy to withdraw BNB collateral, so the recipient will receive slisBNB instead of BNB
  function releaseInTokenFor(address account, uint256 amount) external;

  /// @dev Estimate the amount of slisBNB that can be withdrawn from CDP strategy for the given BNB amount
  /// @notice it uses the current exchange rate between BNB and slisBNB to calculate the estimated amount
  function estimateInToken(address strategy, uint256 amount) external view returns (uint256);
}

interface ISlisBnbProviderCdp {
  function releaseFor(address account, uint256 amount) external;
}

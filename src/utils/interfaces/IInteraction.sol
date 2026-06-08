// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IInteraction {
  function drip(address token) external;

  function borrowed(address token, address usr) external view returns (uint256);

  function paybackFor(address token, uint256 lisUSDAmount, address borrower) external returns (int256);

  function withdrawFor(address borrower, address token, uint256 collateralAmount) external returns (uint256);

  function free(address token, address usr) external view returns (uint256);

  function locked(address token, address usr) external view returns (uint256);

  /// @dev return provider address for a given collateral token
  function helioProviders(address token) external view returns (address);
}

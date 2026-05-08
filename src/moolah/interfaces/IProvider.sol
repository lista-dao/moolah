// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams } from "./IMoolah.sol";

/// @title IErc20CollateralProvider
/// @notice Interface for ERC20-based collateral providers (e.g. SlisBNBProvider).
///         The provider pulls collateral ERC20 tokens from msg.sender on supply and sends them
///         to `receiver` on withdraw, while maintaining any off-chain accounting (e.g. LP tokens).
interface IERC20Provider {
  /// @notice Supply ERC20 collateral to a market on behalf of a user.
  ///         Pulls `assets` of the collateral token from msg.sender.
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    bytes calldata data
  ) external;

  /// @notice Withdraw ERC20 collateral from a market on behalf of a user.
  ///         Sends `assets` of the collateral token to `receiver`.
  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
  ) external;
}

/// @title INativeCollateralProvider
/// @notice Interface for native-token collateral providers (e.g. BNBProvider, ETHProvider).
///         Supply sends native currency via msg.value; withdraw unwraps and sends native currency
///         to the (payable) receiver.
interface INativeProvider {
  /// @notice Supply native-token collateral to a market on behalf of a user.
  ///         The amount is taken from msg.value; the provider wraps it internally.
  function supplyCollateral(MarketParams calldata marketParams, address onBehalf, bytes calldata data) external payable;

  /// @notice Withdraw native-token collateral from a market on behalf of a user.
  ///         Unwraps the collateral and sends native currency to `receiver`.
  function withdrawCollateral(
    MarketParams calldata marketParams,
    uint256 assets,
    address onBehalf,
    address payable receiver
  ) external;
}

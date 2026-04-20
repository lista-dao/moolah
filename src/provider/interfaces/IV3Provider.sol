// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";
import { IProvider } from "./IProvider.sol";

interface IV3Provider is IProvider, IOracle {
  function TOKEN0() external view returns (address);

  function TOKEN1() external view returns (address);

  function FEE() external view returns (uint24);

  function POOL() external view returns (address);

  function tokenId() external view returns (uint256);

  function tickLower() external view returns (int24);

  function tickUpper() external view returns (int24);

  /// @notice Returns total token0 and token1 amounts held by the vault,
  ///         including liquidity-equivalent amounts and uncollected fees.
  function getTotalAmounts() external view returns (uint256 total0, uint256 total1);

  /// @notice Returns the TWAP tick for the pool over the configured TWAP_PERIOD.
  function getTwapTick() external view returns (int24 twapTick);

  /// @notice Deposit token0/token1 into the V3 position and supply resulting
  ///         shares as Moolah collateral on behalf of `onBehalf`.
  function deposit(
    MarketParams calldata marketParams,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address onBehalf
  ) external payable returns (uint256 shares, uint256 amount0Used, uint256 amount1Used);

  /// @notice Withdraw shares from Moolah, remove liquidity, and return
  ///         token0/token1 to `receiver`.
  function withdraw(
    MarketParams calldata marketParams,
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address onBehalf,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);

  /// @notice Redeem shares already held by the caller (e.g. a liquidator)
  ///         for the underlying token0/token1.
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);
}

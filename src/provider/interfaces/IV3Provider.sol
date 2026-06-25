// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { IProvider } from "./IProvider.sol";

/**
 * @title IV3Provider
 * @notice Vault surface for the V3 LP collateral provider. Position internals (tokenId, ticks, pool,
 *         TWAP) live on the DEX adapter (IV3DexAdapter); share pricing lives on the oracle
 *         (IV3ProviderOracle). The vault is no longer an IOracle.
 */
interface IV3Provider is IProvider {
  function TOKEN0() external view returns (address);

  function TOKEN1() external view returns (address);

  /// @notice Wrapped-native token of the pool's chain (WBNB on BSC, WETH on Ethereum). On exit the
  ///         provider unwraps whichever leg equals this to the native coin, so consumers (e.g. the
  ///         liquidator) must treat that leg as native rather than ERC-20.
  function WRAPPED_NATIVE() external view returns (address);

  /// @notice The DEX adapter holding the V3 NFT / idle inventory.
  function ADAPTER() external view returns (address);

  /// @notice Total token0/token1 backing the vault at the current pool spot (display/bots).
  function getTotalAmounts() external view returns (uint256 total0, uint256 total1);

  /// @notice Deposit token0/token1 into the V3 position and supply resulting shares as Moolah
  ///         collateral on behalf of `onBehalf`.
  function deposit(
    MarketParams calldata marketParams,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address onBehalf
  ) external payable returns (uint256 shares, uint256 amount0Used, uint256 amount1Used);

  /// @notice Withdraw shares from Moolah, remove liquidity, and return token0/token1 to `receiver`.
  function withdraw(
    MarketParams calldata marketParams,
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address onBehalf,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);

  /// @notice Withdraw provider shares from Moolah collateral without redeeming the underlying position.
  function withdrawShares(
    MarketParams calldata marketParams,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external;

  /// @notice Supply wallet-held provider shares as Moolah collateral.
  function supplyShares(MarketParams calldata marketParams, uint256 shares, address onBehalf) external;

  /// @notice Redeem shares already held by the caller (e.g. a liquidator) for the underlying token0/token1.
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);
}

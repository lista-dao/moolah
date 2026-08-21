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
  /// @notice token0 of the underlying V3 pool (token0 < token1 by address).
  function TOKEN0() external view returns (address);

  /// @notice token1 of the underlying V3 pool.
  function TOKEN1() external view returns (address);

  /// @notice Wrapped-native token of the pool's chain (WBNB on BSC, WETH on Ethereum). On exit the
  ///         provider unwraps whichever leg equals this to the native coin, so consumers (e.g. the
  ///         liquidator) must treat that leg as native rather than ERC-20.
  function WRAPPED_NATIVE() external view returns (address);

  /// @notice The DEX adapter holding the V3 NFT / idle inventory.
  function ADAPTER() external view returns (address);

  /// @notice Total token0/token1 backing the vault at the current pool spot (display/bots).
  function getTotalAmounts() external view returns (uint256 total0, uint256 total1);

  /// @notice Total token0/token1 backing the vault at the FAIR price (idle + fees included). This is the
  ///         ratio a subsequent deposit binds to; size deposit legs in this ratio to minimise the refund.
  function getFairComposition() external view returns (uint256 total0, uint256 total1);

  /// @notice Deposit token0/token1 into the V3 position and supply resulting shares as Moolah
  ///         collateral on behalf of `onBehalf`.
  /// @param marketParams   target Moolah market (collateral token must be this vault).
  /// @param amount0Desired token0 offered (unused excess is refunded).
  /// @param amount1Desired token1 offered (unused excess is refunded).
  /// @param amount0Min     min token0 that must be consumed, else revert.
  /// @param amount1Min     min token1 that must be consumed, else revert.
  /// @param minShares      share-slippage floor: revert if minted shares < this (0 disables).
  /// @param onBehalf       Moolah collateral owner credited with the shares.
  /// @return shares        shares minted and supplied.
  /// @return amount0Used   token0 actually consumed.
  /// @return amount1Used   token1 actually consumed.
  function deposit(
    MarketParams calldata marketParams,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 minShares,
    address onBehalf
  ) external payable returns (uint256 shares, uint256 amount0Used, uint256 amount1Used);

  /// @notice Withdraw shares from Moolah, remove liquidity, and return token0/token1 to `receiver`.
  /// @param marketParams market to pull the collateral from.
  /// @param shares       shares to burn.
  /// @param minAmount0   min token0 delivered, else revert.
  /// @param minAmount1   min token1 delivered, else revert.
  /// @param onBehalf     collateral owner whose shares are withdrawn.
  /// @param receiver     recipient of the underlying (wrapped-native leg paid as native coin).
  /// @return amount0     token0 delivered.
  /// @return amount1     token1 delivered.
  function withdraw(
    MarketParams calldata marketParams,
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address onBehalf,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);

  /// @notice Withdraw provider shares from Moolah collateral without redeeming the underlying position.
  /// @param marketParams market to pull the collateral from.
  /// @param shares       shares to withdraw.
  /// @param onBehalf     collateral owner whose shares are withdrawn.
  /// @param receiver     recipient of the share tokens.
  function withdrawShares(
    MarketParams calldata marketParams,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external;

  /// @notice Supply wallet-held provider shares as Moolah collateral.
  /// @param marketParams market to supply into.
  /// @param shares       shares to supply.
  /// @param onBehalf     collateral owner credited with the shares.
  function supplyShares(MarketParams calldata marketParams, uint256 shares, address onBehalf) external;

  /// @notice Redeem shares already held by the caller (e.g. a liquidator) for the underlying token0/token1.
  /// @param shares     shares to redeem.
  /// @param minAmount0 min token0 delivered, else revert.
  /// @param minAmount1 min token1 delivered, else revert.
  /// @param receiver   recipient of the underlying (wrapped-native leg paid as native coin).
  /// @return amount0   token0 delivered.
  /// @return amount1   token1 delivered.
  function redeemShares(
    uint256 shares,
    uint256 minAmount0,
    uint256 minAmount1,
    address receiver
  ) external returns (uint256 amount0, uint256 amount1);

  function depositWhitelistEnabled() external view returns (bool);

  function depositWhitelist(address account) external view returns (bool);

  function setDepositWhitelistEnabled(bool enabled) external;

  function setDepositWhitelist(address[] calldata accounts, bool allowed) external;
}

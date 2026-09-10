// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title IV3PoolMinimal
 * @author Lista DAO
 * @notice Minimal Uniswap/PancakeSwap V3 pool reader that decodes only the slot0 fields the adapter
 *         actually consumes (sqrtPriceX96, tick). The full slot0 tuple ends with a `feeProtocol` field
 *         whose width differs across forks — Uniswap V3 / lista-v3 pack it as uint8, PancakeSwap V3 as
 *         uint32. Decoding the whole tuple through a uint8-typed interface reverts against a Pancake
 *         pool (dirty high bits). Stopping the decode at `tick` makes the read width-agnostic, so the
 *         adapter works against any V3 flavor (and the integration tests can fork a live Pancake pool).
 */
interface IV3PoolMinimal {
  function slot0() external view returns (uint160 sqrtPriceX96, int24 tick);

  /// @notice Global fee growth per unit of liquidity, Q128.
  function feeGrowthGlobal0X128() external view returns (uint256);

  function feeGrowthGlobal1X128() external view returns (uint256);

  /// @notice Tick state. Decodes only the first four fields (liquidityGross, liquidityNet,
  ///         feeGrowthOutside0X128, feeGrowthOutside1X128) — the two fee-growth values are all the
  ///         pending-fee simulation needs, and stopping the decode there keeps the read width-agnostic
  ///         across V3 flavors (see the slot0 note above).
  function ticks(
    int24 tick
  )
    external
    view
    returns (uint128 liquidityGross, int128 liquidityNet, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128);
}

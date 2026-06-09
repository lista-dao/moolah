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
}

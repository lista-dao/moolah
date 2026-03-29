// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import "../../core/interfaces/IListaV3Pool.sol";
import "../../core/interfaces/IListaV3Factory.sol";
import "./PoolAddress.sol";

/// @notice Provides validation for callbacks from Lista V3 Pools
library CallbackValidation {
  /// @notice Returns the address of a valid Lista V3 Pool
  /// @param factory The contract address of the Lista V3 factory
  /// @param tokenA The contract address of either token0 or token1
  /// @param tokenB The contract address of the other token
  /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
  /// @return pool The V3 pool contract address
  function verifyCallback(
    address factory,
    address tokenA,
    address tokenB,
    uint24 fee
  ) internal view returns (IListaV3Pool pool) {
    return
      verifyCallback(
        factory,
        PoolAddress.PoolKey({
          token0: tokenA < tokenB ? tokenA : tokenB,
          token1: tokenA < tokenB ? tokenB : tokenA,
          fee: fee
        })
      );
  }

  /// @notice Returns the address of a valid Lista V3 Pool
  /// @param factory The contract address of the Lista V3 factory
  /// @param poolKey The identifying key of the V3 pool
  /// @return pool The V3 pool contract address
  function verifyCallback(
    address factory,
    PoolAddress.PoolKey memory poolKey
  ) internal view returns (IListaV3Pool pool) {
    pool = IListaV3Pool(IListaV3Factory(factory).getPool(poolKey.token0, poolKey.token1, poolKey.fee));
    require(msg.sender == address(pool));
  }
}

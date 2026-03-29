// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {
  /// @notice The identifying key of the pool
  struct PoolKey {
    address token0;
    address token1;
    uint24 fee;
  }

  /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
  function getPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
    if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    return PoolKey({ token0: tokenA, token1: tokenB, fee: fee });
  }

  /// @notice Deterministically computes the pool address given the factory, PoolKey, and init code hash
  /// @param factory The Lista V3 factory contract address
  /// @param key The PoolKey
  /// @param initCodeHash The keccak256 of the pool proxy creation code (from factory.poolInitCodeHash())
  /// @return pool The contract address of the V3 pool
  function computeAddress(
    address factory,
    PoolKey memory key,
    bytes32 initCodeHash
  ) internal pure returns (address pool) {
    require(key.token0 < key.token1);
    pool = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(hex"ff", factory, keccak256(abi.encode(key.token0, key.token1, key.fee)), initCodeHash)
          )
        )
      )
    );
  }
}

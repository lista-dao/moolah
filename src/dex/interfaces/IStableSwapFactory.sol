// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal StableSwapFactory interface used to authorize pools by provenance.
interface IStableSwapFactory {
  /// @dev Layout must match StableSwapFactory.StableSwapPairInfo
  struct StableSwapPairInfo {
    address swapContract;
    address token0;
    address token1;
    address LPContract;
  }

  /// @dev Every pool registered for the pair; the factory sorts the arguments itself
  function getPairInfos(address tokenA, address tokenB) external view returns (StableSwapPairInfo[] memory);
}

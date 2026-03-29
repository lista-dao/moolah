// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import "../interfaces/IPeripheryImmutableState.sol";

/// @title Immutable state
/// @notice State used by periphery contracts — stored as regular storage for UUPS compatibility.
abstract contract PeripheryImmutableState is IPeripheryImmutableState {
  /// @inheritdoc IPeripheryImmutableState
  address public override factory;
  /// @inheritdoc IPeripheryImmutableState
  address public override WETH9;

  /// @dev The keccak256 of the pool proxy creation code, used to compute pool addresses.
  bytes32 public poolInitCodeHash;

  constructor(address _factory, address _WETH9) {
    factory = _factory;
    WETH9 = _WETH9;
  }
}

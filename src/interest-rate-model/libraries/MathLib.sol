// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WAD } from "moolah/libraries/MathLib.sol";

int256 constant WAD_INT = int256(WAD);

/// @title MathLib
/// @author Lista DAO
/// @notice Library to manage fixed-point arithmetic on signed integers.
library MathLib {
  /// @dev Returns the multiplication of `x` by `y` (in WAD) rounded towards 0.
  function wMulToZero(int256 x, int256 y) internal pure returns (int256) {
    return (x * y) / WAD_INT;
  }

  /// @dev Returns the division of `x` by `y` (in WAD) rounded towards 0.
  function wDivToZero(int256 x, int256 y) internal pure returns (int256) {
    return (x * WAD_INT) / y;
  }
}

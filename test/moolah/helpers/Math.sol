// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library Math {
  function max(uint256 a, uint256 b) internal pure returns (uint256) {
    return a > b ? a : b;
  }

  function min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

  function zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
    return x <= y ? 0 : x - y;
  }
}

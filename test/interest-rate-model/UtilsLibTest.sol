// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "interest-rate-model/libraries/UtilsLib.sol";

import "forge-std/Test.sol";

contract UtilsTest is Test {
  using UtilsLib for int256;

  function testBoundExpected(int256 x, int256 low, int256 high) public pure {
    int256 expected = x <= high ? (x >= low ? x : low) : (low <= high ? high : low);
    assertEq(x.bound(low, high), expected);
  }

  function testBoundMaxMin(int256 x, int256 low, int256 high) public pure {
    int256 maxMin = _max(_min(x, high), low);
    assertEq(x.bound(low, high), maxMin);
  }

  function _min(int256 a, int256 b) private pure returns (int256) {
    return a > b ? b : a;
  }

  function _max(int256 a, int256 b) private pure returns (int256) {
    return a > b ? a : b;
  }
}

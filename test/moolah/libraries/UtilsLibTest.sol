// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "moolah/libraries/ErrorsLib.sol";
import "moolah/libraries/UtilsLib.sol";

contract UtilsLibTest is Test {
  using UtilsLib for uint256;

  function testExactlyOneZero(uint256 x, uint256 y) public pure {
    assertEq(UtilsLib.exactlyOneZero(x, y), (x > 0 && y == 0) || (x == 0 && y > 0));
  }

  function testMin(uint256 x, uint256 y) public pure {
    assertEq(UtilsLib.min(x, y), x < y ? x : y);
  }

  function testToUint128(uint256 x) public pure {
    vm.assume(x <= type(uint128).max);
    assertEq(uint256(x.toUint128()), x);
  }

  function testToUint128Revert(uint256 x) public {
    vm.assume(x > type(uint128).max);
    vm.expectRevert(bytes(ErrorsLib.MAX_UINT128_EXCEEDED));
    x.toUint128();
  }

  function testZeroFloorSub(uint256 x, uint256 y) public pure {
    assertEq(UtilsLib.zeroFloorSub(x, y), x < y ? 0 : x - y);
  }
}

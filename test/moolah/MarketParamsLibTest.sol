// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";

contract MarketParamsLibTest is Test {
  using MarketParamsLib for MarketParams;

  function testMarketParamsId(MarketParams memory marketParamsFuzz) public pure {
    assertEq(Id.unwrap(marketParamsFuzz.id()), keccak256(abi.encode(marketParamsFuzz)));
  }
}

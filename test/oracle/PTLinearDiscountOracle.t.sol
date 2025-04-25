// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PTLinearDiscountOracle, ILinearDiscountOracle } from "../../src/oracle/PTLinearDiscountOracle.sol";

interface IPTExpiry {
  function expiry() external view returns (uint256);
}

contract PTLinearDiscountOracleTest is Test {
  PTLinearDiscountOracle ptLinearDiscountOracle;
  address ptSusde26Jun2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
  address ptSusde26Jun2025Oracle = 0x2AD358a2972aD56937A18b5D90A4F087C007D08d;

  address admin = address(0x01);
  address manager = address(0x02);

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    PTLinearDiscountOracle impl = new PTLinearDiscountOracle();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        PTLinearDiscountOracle.initialize.selector,
        admin,
        manager,
        ptSusde26Jun2025,
        ptSusde26Jun2025Oracle
      )
    );
    ptLinearDiscountOracle = PTLinearDiscountOracle(address(proxy_));

    assertEq(ptLinearDiscountOracle.asset(), ptSusde26Jun2025);
    assertEq(ptLinearDiscountOracle.discountOracle(), ptSusde26Jun2025Oracle);
    assertEq(ptLinearDiscountOracle.decimals(), 8);
  }

  function test_peek() public view {
    uint256 price = ptLinearDiscountOracle.peek(ptSusde26Jun2025);
    uint256 maturity = IPTExpiry(ptSusde26Jun2025).expiry();
    uint256 timeLeft = (maturity > block.timestamp) ? maturity - block.timestamp : 0;
    uint256 expected = 1e18 - ILinearDiscountOracle(ptSusde26Jun2025Oracle).getDiscount(timeLeft);

    assertEq(price, expected / 1e10); // 1e8 is the decimal of the oracle
  }
}

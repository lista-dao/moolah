// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PTLinearDiscountOracle, ILinearDiscountOracle } from "../../src/oracle/PTLinearDiscountOracle.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

interface IPTExpiry {
  function expiry() external view returns (uint256);
}

contract PTLinearDiscountOracleTest is Test {
  PTLinearDiscountOracle ptLinearDiscountOracle;
  address ptSusde26Jun2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
  address ptSusde26Jun2025Oracle = 0x2AD358a2972aD56937A18b5D90A4F087C007D08d;
  address loanAsset = makeAddr("loanAsset");
  address loanTokenOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  address admin = address(0x01);

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    vm.mockCall(loanTokenOracle, abi.encodeWithSelector(IOracle.peek.selector, loanAsset), abi.encode(1e8));

    PTLinearDiscountOracle impl = new PTLinearDiscountOracle();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        PTLinearDiscountOracle.initialize.selector,
        admin,
        ptSusde26Jun2025,
        ptSusde26Jun2025Oracle,
        loanAsset,
        loanTokenOracle
      )
    );
    ptLinearDiscountOracle = PTLinearDiscountOracle(address(proxy_));

    assertEq(ptLinearDiscountOracle.asset(), ptSusde26Jun2025);
    assertEq(ptLinearDiscountOracle.discountOracle(), ptSusde26Jun2025Oracle);
    assertEq(ptLinearDiscountOracle.decimals(), 8);
    assertEq(ptLinearDiscountOracle.loanAsset(), loanAsset);
    assertEq(address(ptLinearDiscountOracle.loanTokenOracle()), loanTokenOracle);
  }

  function test_peek() public view {
    uint256 price = ptLinearDiscountOracle.peek(ptSusde26Jun2025);
    uint256 maturity = IPTExpiry(ptSusde26Jun2025).expiry();
    uint256 timeLeft = (maturity > block.timestamp) ? maturity - block.timestamp : 0;
    uint256 expected = 1e18 - ILinearDiscountOracle(ptSusde26Jun2025Oracle).getDiscount(timeLeft);

    assertEq(price, expected / 1e10); // 1e8 is the decimal of the oracle

    uint256 loanPrice = IOracle(loanTokenOracle).peek(loanAsset);
    assertEq(loanPrice, 1e8);
  }
}

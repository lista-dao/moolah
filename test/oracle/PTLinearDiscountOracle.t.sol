// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PTLinearDiscountOracle, ILinearDiscountOracle } from "../../src/oracle/PTLinearDiscountOracle.sol";
import { IOracle, TokenConfig } from "../../src/moolah/interfaces/IOracle.sol";

interface IPTExpiry {
  function expiry() external view returns (uint256);
}

contract PTLinearDiscountOracleTest is Test {
  PTLinearDiscountOracle ptLinearDiscountOracle;
  address ptSusde26Jun2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
  address ptSusde26Jun2025Oracle = 0x2AD358a2972aD56937A18b5D90A4F087C007D08d;
  address loanAsset = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
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
    assertEq(loanPrice, ptLinearDiscountOracle.peek(loanAsset));
  }

  function test_getTokenConfig() public {
    TokenConfig memory config = ptLinearDiscountOracle.getTokenConfig(ptSusde26Jun2025);
    assertEq(config.asset, ptSusde26Jun2025);
    assertEq(config.oracles[0], address(ptLinearDiscountOracle));
    assertEq(config.oracles[1], address(0));
    assertEq(config.oracles[2], address(0));
    assertEq(config.enableFlagsForOracles[0], true);
    assertEq(config.enableFlagsForOracles[1], false);
    assertEq(config.enableFlagsForOracles[1], false);
    assertEq(config.timeDeltaTolerance, 0);

    TokenConfig memory loanConfig = ptLinearDiscountOracle.getTokenConfig(loanAsset);
    TokenConfig memory expectLoanConfig = IOracle(loanTokenOracle).getTokenConfig(loanAsset);

    assertEq(loanConfig.asset, loanAsset);
    assertEq(loanConfig.oracles[0], expectLoanConfig.oracles[0]);
    assertEq(loanConfig.oracles[1], expectLoanConfig.oracles[1]);
    assertEq(loanConfig.oracles[2], expectLoanConfig.oracles[2]);
    assertEq(loanConfig.enableFlagsForOracles[0], expectLoanConfig.enableFlagsForOracles[0]);
    assertEq(loanConfig.enableFlagsForOracles[1], expectLoanConfig.enableFlagsForOracles[1]);
    assertEq(loanConfig.enableFlagsForOracles[2], expectLoanConfig.enableFlagsForOracles[2]);
    assertEq(loanConfig.timeDeltaTolerance, expectLoanConfig.timeDeltaTolerance);

    address foo = makeAddr("foo");
    vm.expectRevert("PTLinearDiscountOracle: Invalid asset");
    ptLinearDiscountOracle.getTokenConfig(foo);
  }
}

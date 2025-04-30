// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PTLinearDiscountMarketOracle, ILinearDiscountOracle } from "../../src/oracle/PTLinearDiscountMarketOracle.sol";
import { IOracle, TokenConfig } from "../../src/moolah/interfaces/IOracle.sol";

interface IPTExpiry {
  function expiry() external view returns (uint256);
}

contract PTLinearDiscountMarketOracleTest is Test {
  PTLinearDiscountMarketOracle ptLinearDiscountOracle;

  address ptClisBNB30OCT2025 = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
  address discountOracle = 0xDF1dED2EA9dEa5456533A0C92f6EF7d6F2ACc1c0;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address loanAsset = WBNB;
  address loanTokenOracle = multiOracle;

  address admin = address(0x01);

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    PTLinearDiscountMarketOracle impl = new PTLinearDiscountMarketOracle();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        PTLinearDiscountMarketOracle.initialize.selector,
        admin,
        ptClisBNB30OCT2025,
        discountOracle,
        WBNB,
        multiOracle,
        loanAsset,
        loanTokenOracle
      )
    );
    ptLinearDiscountOracle = PTLinearDiscountMarketOracle(address(proxy_));

    assertEq(ptLinearDiscountOracle.asset(), ptClisBNB30OCT2025);
    assertEq(ptLinearDiscountOracle.discountOracle(), discountOracle);
    assertEq(ptLinearDiscountOracle.decimals(), 8);
    assertEq(ptLinearDiscountOracle.baseToken(), WBNB);
    assertEq(address(ptLinearDiscountOracle.baseTokenOracle()), multiOracle);
    assertEq(ptLinearDiscountOracle.loanAsset(), loanAsset);
    assertEq(address(ptLinearDiscountOracle.loanTokenOracle()), loanTokenOracle);
    assertTrue(ptLinearDiscountOracle.hasRole(ptLinearDiscountOracle.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_peek_pt() public view {
    uint256 price = ptLinearDiscountOracle.peek(ptClisBNB30OCT2025);

    uint256 basePrice = IOracle(multiOracle).peek(WBNB);

    uint256 maturity = IPTExpiry(ptClisBNB30OCT2025).expiry();
    uint256 timeLeft = (maturity > block.timestamp) ? maturity - block.timestamp : 0;
    uint256 discount = 1e18 - ILinearDiscountOracle(discountOracle).getDiscount(timeLeft);

    assertEq(price, (basePrice * discount) / 1e18); // price equals to discount applied to the base price
  }

  function test_peek_loan() public view {
    uint256 price = ptLinearDiscountOracle.peek(loanAsset);

    uint256 loanPrice = IOracle(multiOracle).peek(loanAsset);

    assertEq(price, loanPrice); // price equals to the loan asset price
  }

  function test_getTokenConfig() public {
    TokenConfig memory config = ptLinearDiscountOracle.getTokenConfig(ptClisBNB30OCT2025);
    assertEq(config.asset, ptClisBNB30OCT2025);
    assertEq(config.oracles[0], address(ptLinearDiscountOracle));
    assertEq(config.oracles[1], address(0));
    assertEq(config.oracles[2], address(0));
    assertEq(config.enableFlagsForOracles[0], true);
    assertEq(config.enableFlagsForOracles[1], false);
    assertEq(config.enableFlagsForOracles[2], false);
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

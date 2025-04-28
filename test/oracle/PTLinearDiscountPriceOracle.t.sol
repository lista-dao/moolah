// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PTLinearDiscountMarketOracle, ILinearDiscountOracle } from "../../src/oracle/PTLinearDiscountMarketOracle.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

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
}

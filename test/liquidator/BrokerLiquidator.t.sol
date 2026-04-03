// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { BrokerLiquidator, IBrokerLiquidator } from "liquidator/BrokerLiquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";
import { MockSmartProvider } from "./mocks/MockSmartProvider.sol";

contract BrokerLiquidatorTest is BaseTest {
  using MarketParamsLib for MarketParams;

  BrokerLiquidator brokerLiquidator;
  address BOT;
  address MANAGER_ADDR;
  MockSmartProvider smartProvider;

  function setUp() public override {
    super.setUp();

    BOT = makeAddr("Bot");
    MANAGER_ADDR = OWNER;

    BrokerLiquidator impl = new BrokerLiquidator(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, OWNER, OWNER, BOT)
    );
    brokerLiquidator = BrokerLiquidator(payable(address(proxy)));

    smartProvider = new MockSmartProvider(address(loanToken), address(collateralToken));
  }

  // ==================== batchSetSmartProviders ====================

  function testBatchSetSmartProviders() public {
    address[] memory providers = new address[](2);
    providers[0] = address(smartProvider);
    providers[1] = makeAddr("Provider2");

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);

    assertTrue(brokerLiquidator.smartProviders(address(smartProvider)));
    assertTrue(brokerLiquidator.smartProviders(providers[1]));
  }

  function testBatchSetSmartProvidersRemove() public {
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);
    assertTrue(brokerLiquidator.smartProviders(address(smartProvider)));

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, false);
    assertFalse(brokerLiquidator.smartProviders(address(smartProvider)));
  }

  function testBatchSetSmartProvidersEmitsEvents() public {
    address[] memory providers = new address[](2);
    providers[0] = address(smartProvider);
    providers[1] = makeAddr("Provider2");

    vm.expectEmit(true, true, true, true);
    emit BrokerLiquidator.SmartProvidersChanged(providers[0], true);
    vm.expectEmit(true, true, true, true);
    emit BrokerLiquidator.SmartProvidersChanged(providers[1], true);

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);
  }

  function testBatchSetSmartProvidersRevertsIfNotManager() public {
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);

    vm.prank(BOT);
    vm.expectRevert();
    brokerLiquidator.batchSetSmartProviders(providers, true);
  }

  function testBatchSetSmartProvidersEmpty() public {
    address[] memory providers = new address[](0);

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);
    // no revert, no-op
  }

  // ==================== redeemSmartCollateral ====================

  function testRedeemSmartCollateral() public {
    // whitelist provider
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);

    uint256 lpAmount = 1e18;
    vm.prank(BOT);
    (uint256 token0Out, uint256 token1Out) = brokerLiquidator.redeemSmartCollateral(
      address(smartProvider),
      lpAmount,
      0,
      0
    );

    assertEq(token0Out, lpAmount / 2);
    assertEq(token1Out, lpAmount / 2);
    assertEq(loanToken.balanceOf(address(brokerLiquidator)), token0Out);
    assertEq(collateralToken.balanceOf(address(brokerLiquidator)), token1Out);
  }

  function testRedeemSmartCollateralRevertsIfNotWhitelisted() public {
    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    brokerLiquidator.redeemSmartCollateral(address(smartProvider), 1e18, 0, 0);
  }

  function testRedeemSmartCollateralRevertsIfNotBot() public {
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);

    vm.prank(MANAGER_ADDR);
    vm.expectRevert();
    brokerLiquidator.redeemSmartCollateral(address(smartProvider), 1e18, 0, 0);
  }

  function testRedeemSmartCollateralRevertsAfterProviderRemoved() public {
    address[] memory providers = new address[](1);
    providers[0] = address(smartProvider);

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, true);

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.batchSetSmartProviders(providers, false);

    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    brokerLiquidator.redeemSmartCollateral(address(smartProvider), 1e18, 0, 0);
  }
}

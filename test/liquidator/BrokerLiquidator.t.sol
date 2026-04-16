// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../moolah/BaseTest.sol";

import { BrokerLiquidator, IBrokerLiquidator } from "liquidator/BrokerLiquidator.sol";
import { MarketParamsLib, MarketParams, Id } from "moolah/libraries/MarketParamsLib.sol";
import { MockSmartProvider } from "./mocks/MockSmartProvider.sol";
import { MockStableSwapLPCollateral } from "./mocks/MockStableSwapLPCollateral.sol";
import { MockOneInch } from "./mocks/MockOneInch.sol";

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

  // ==================== batchSetSmartProviders zero address ====================

  function testBatchSetSmartProvidersRevertsOnZeroAddress() public {
    address[] memory providers = new address[](2);
    providers[0] = address(smartProvider);
    providers[1] = address(0);

    vm.prank(MANAGER_ADDR);
    vm.expectRevert("zero address");
    brokerLiquidator.batchSetSmartProviders(providers, true);
  }

  // ==================== _isSmartCollateral (via liquidate) ====================

  function testLiquidateRevertsForSmartCollateral() public {
    // Create a MockSmartProvider whose TOKEN() returns a MockStableSwapLPCollateral
    // and the collateral's minter() returns the MockSmartProvider
    MockStableSwapLPCollateral mockLPCollateral = new MockStableSwapLPCollateral(
      "MockLP",
      "MLP",
      address(smartProvider)
    );
    // Configure smartProvider so TOKEN() returns the LP collateral address
    smartProvider.setCollateralToken(address(mockLPCollateral));

    // Create a market with this LP collateral
    MarketParams memory smartMarketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(mockLPCollateral),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    moolah.createMarket(smartMarketParams);
    bytes32 smartMarketId = Id.unwrap(smartMarketParams.id());

    // Deploy a mock broker that returns the correct MARKET_ID
    MockBrokerForLiquidation mockBroker = new MockBrokerForLiquidation(smartMarketParams.id());

    // Mock the brokers call so whitelist validation passes
    vm.mockCall(
      address(moolah),
      abi.encodeWithSelector(moolah.brokers.selector, smartMarketParams.id()),
      abi.encode(address(mockBroker))
    );

    // Whitelist the market
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setMarketToBroker(smartMarketId, address(mockBroker), true);

    // Attempt to liquidate should revert with SmartCollateralMustUseDedicatedFunction
    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.SmartCollateralMustUseDedicatedFunction.selector);
    brokerLiquidator.liquidate(smartMarketId, address(1), 1e18, 0);
  }

  function testLiquidateAllowsNormalCollateral() public {
    // Normal collateral (ERC20Mock) does not have minter(), so _isSmartCollateral returns false
    bytes32 normalMarketId = Id.unwrap(marketParams.id());

    MockBrokerForLiquidation mockBroker = new MockBrokerForLiquidation(marketParams.id());

    vm.mockCall(
      address(moolah),
      abi.encodeWithSelector(moolah.brokers.selector, marketParams.id()),
      abi.encode(address(mockBroker))
    );

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setMarketToBroker(normalMarketId, address(mockBroker), true);

    // Should NOT revert with SmartCollateralMustUseDedicatedFunction
    // It will revert inside broker.liquidate (mock is a no-op), but the smart collateral check passes
    vm.prank(BOT);
    brokerLiquidator.liquidate(normalMarketId, address(1), 1e18, 0);
    // If we get here, the _isSmartCollateral check did not block normal collateral
  }

  // ==================== sellBNB ====================

  function testSellBNB() public {
    MockOneInch mockDex = new MockOneInch();
    address BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Whitelist BNB, loanToken, and the pair
    vm.startPrank(MANAGER_ADDR);
    brokerLiquidator.setTokenWhitelist(BNB_ADDRESS, true);
    brokerLiquidator.setTokenWhitelist(address(loanToken), true);
    brokerLiquidator.setPairWhitelist(address(mockDex), true);
    vm.stopPrank();

    // Fund the liquidator with BNB
    uint256 amountIn = 1 ether;
    uint256 amountOutMin = 2000e18;
    deal(address(brokerLiquidator), amountIn);

    bytes memory swapData = abi.encodeWithSelector(
      mockDex.swap.selector,
      BNB_ADDRESS,
      address(loanToken),
      amountIn,
      amountOutMin
    );

    vm.prank(BOT);
    brokerLiquidator.sellBNB(address(mockDex), address(loanToken), amountIn, amountOutMin, swapData);

    assertEq(address(brokerLiquidator).balance, 0);
    assertEq(loanToken.balanceOf(address(brokerLiquidator)), amountOutMin);
  }

  function testSellBNBRevertsIfNotBot() public {
    vm.prank(MANAGER_ADDR);
    vm.expectRevert();
    brokerLiquidator.sellBNB(address(1), address(loanToken), 1 ether, 0, "");
  }

  function testSellBNBRevertsIfBNBNotWhitelisted() public {
    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    brokerLiquidator.sellBNB(address(1), address(loanToken), 1 ether, 0, "");
  }

  function testSellBNBRevertsIfInsufficientBalance() public {
    address BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    vm.startPrank(MANAGER_ADDR);
    brokerLiquidator.setTokenWhitelist(BNB_ADDRESS, true);
    brokerLiquidator.setTokenWhitelist(address(loanToken), true);
    brokerLiquidator.setPairWhitelist(address(1), true);
    vm.stopPrank();

    // No BNB in contract
    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.ExceedAmount.selector);
    brokerLiquidator.sellBNB(address(1), address(loanToken), 1 ether, 0, "");
  }
}

/// @dev Minimal mock broker that returns a MARKET_ID for whitelist validation
contract MockBrokerForLiquidation {
  Id public immutable MARKET_ID;

  constructor(Id _marketId) {
    MARKET_ID = _marketId;
  }

  function liquidate(MarketParams memory, address, uint256, uint256, bytes calldata) external {
    // no-op for testing
  }
}

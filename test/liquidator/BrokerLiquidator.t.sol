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

    // The guard reads reflowBlacklist: the LP token must be listed
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setReflowBlacklist(address(mockLPCollateral), true);

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

  // ==================== keeper assignment / self-funded path (audit fixes) ====================

  /// @dev registers `mp` on the liquidator with a mock broker (Moolah.brokers is mocked to match)
  function _registerMarket(MarketParams memory mp, address broker) internal returns (bytes32 id) {
    if (moolah.market(mp.id()).lastUpdate == 0) moolah.createMarket(mp);
    id = Id.unwrap(mp.id());
    vm.mockCall(address(moolah), abi.encodeWithSelector(moolah.brokers.selector, mp.id()), abi.encode(broker));
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setMarketToBroker(id, broker, true);
  }

  function testSetMarketKeeperAllowsNormalMarket() public {
    address keeper = makeAddr("keeper");
    bytes32 id = _registerMarket(marketParams, address(new MockBrokerForLiquidation(marketParams.id())));

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);
    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper(id, keeper, true);
    assertTrue(brokerLiquidator.marketKeepers(id, keeper));
  }

  function testSetMarketKeeperRevertsForSmartCollateral() public {
    address keeper = makeAddr("keeper");
    MockStableSwapLPCollateral mockLPCollateral = new MockStableSwapLPCollateral(
      "MockLP",
      "MLP",
      address(smartProvider)
    );
    smartProvider.setCollateralToken(address(mockLPCollateral));
    MarketParams memory smartMarketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(mockLPCollateral),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    bytes32 id = _registerMarket(smartMarketParams, address(new MockBrokerForLiquidation(smartMarketParams.id())));

    vm.startPrank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);
    brokerLiquidator.setReflowBlacklist(address(mockLPCollateral), true);
    vm.stopPrank();

    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.SmartCollateralMustUseDedicatedFunction.selector);
    brokerLiquidator.setMarketKeeper(id, keeper, true);
    assertFalse(brokerLiquidator.marketKeepers(id, keeper));

    // the guard follows the list, not the token's shape: once delisted the market is assignable
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setReflowBlacklist(address(mockLPCollateral), false);
    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper(id, keeper, true);
    assertTrue(brokerLiquidator.marketKeepers(id, keeper));
  }

  /// @dev WBNB-like collateral: unknown selectors fall into a state-writing fallback. Probing such a
  ///      token inside a staticcall burns 63/64 of the gas; the list lookup must not touch the token.
  function testSetMarketKeeperCheapForCollateralWithStateWritingFallback() public {
    address keeper = makeAddr("keeper");
    FallbackDepositMock wbnbLike = new FallbackDepositMock();
    MarketParams memory mp = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(wbnbLike),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    bytes32 id = _registerMarket(mp, address(new MockBrokerForLiquidation(mp.id())));
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);

    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper{ gas: 200_000 }(id, keeper, true);
    assertTrue(brokerLiquidator.marketKeepers(id, keeper));
    assertEq(wbnbLike.fallbackCalls(), 0, "collateral token was called");
  }

  function testLiquidateCheapForCollateralWithStateWritingFallback() public {
    FallbackDepositMock wbnbLike = new FallbackDepositMock();
    MarketParams memory mp = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(wbnbLike),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    bytes32 id = _registerMarket(mp, address(new MockBrokerForLiquidation(mp.id())));

    // the mock broker's liquidate is a no-op, so this only exercises the pre-checks
    vm.prank(BOT);
    brokerLiquidator.liquidate{ gas: 300_000 }(id, address(1), 1e18, 0);
    assertEq(wbnbLike.fallbackCalls(), 0, "collateral token was called");
  }

  function testSetMarketKeeperRevertsOnBrokerMismatch() public {
    address keeper = makeAddr("keeper");
    bytes32 id = _registerMarket(marketParams, address(new MockBrokerForLiquidation(marketParams.id())));
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);

    // Moolah no longer reports the registered broker for this market
    vm.clearMockedCalls();

    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.BrokerMarketIdMismatch.selector);
    brokerLiquidator.setMarketKeeper(id, keeper, true);
  }

  function testSetMarketKeeperRemovalSkipsMarketChecks() public {
    address keeper = makeAddr("keeper");
    bytes32 id = _registerMarket(marketParams, address(new MockBrokerForLiquidation(marketParams.id())));
    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);
    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper(id, keeper, true);

    // removal stays possible even when the market could no longer be assigned
    vm.clearMockedCalls();
    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper(id, keeper, false);
    assertFalse(brokerLiquidator.marketKeepers(id, keeper));
  }

  function _setupCallbackMarket(
    ERC20Mock loan
  ) internal returns (bytes32 id, MockCallbackBroker broker, address keeper) {
    keeper = makeAddr("keeper");
    MarketParams memory mp = MarketParams({
      loanToken: address(loan),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.8e18
    });
    broker = new MockCallbackBroker(mp.id(), address(loan), address(collateralToken));
    collateralToken.setBalance(address(broker), broker.SEIZED());
    id = _registerMarket(mp, address(broker));

    vm.prank(MANAGER_ADDR);
    brokerLiquidator.setKeeper(keeper, true);
    vm.prank(BOT);
    brokerLiquidator.setMarketKeeper(id, keeper, true);

    loan.setBalance(keeper, 1_000 ether);
    vm.prank(keeper);
    loan.approve(address(brokerLiquidator), type(uint256).max);
    // residual balance held by the liquidator; the keeper path must never spend it
    loan.setBalance(address(brokerLiquidator), 500 ether);
  }

  function testKeeperLiquidatePullsExactRepaymentFromKeeper() public {
    ERC20Mock loan = new ERC20Mock();
    (bytes32 id, MockCallbackBroker broker, address keeper) = _setupCallbackMarket(loan);

    vm.prank(keeper);
    (uint256 seized, uint256 repaid) = brokerLiquidator.keeperLiquidate(id, address(1), 1, 0, type(uint256).max);

    assertEq(seized, broker.SEIZED());
    assertEq(repaid, broker.REPAID());
    assertEq(collateralToken.balanceOf(keeper), broker.SEIZED());
    assertEq(loan.balanceOf(keeper), 1_000 ether - broker.REPAID());
    assertEq(loan.balanceOf(address(brokerLiquidator)), 500 ether, "liquidator balance was used");
    assertEq(loan.balanceOf(address(broker)), broker.REPAID());
  }

  function testKeeperLiquidateRevertsOnFeeOnTransferLoanToken() public {
    FeeOnTransferMock loan = new FeeOnTransferMock();
    (bytes32 id, , address keeper) = _setupCallbackMarket(loan);

    // the keeper's transfer arrives short; the liquidator must not cover the gap from its own balance
    vm.prank(keeper);
    vm.expectRevert(BrokerLiquidator.InsufficientRepayment.selector);
    brokerLiquidator.keeperLiquidate(id, address(1), 1, 0, type(uint256).max);
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

interface ILiquidateCallback {
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external;
}

/// @dev Mock broker that mimics LendingBroker's liquidation flow towards the liquidator: send the
///      seized collateral, call back with the repayment amount, then pull that amount.
contract MockCallbackBroker {
  Id public immutable MARKET_ID;
  address public immutable loan;
  address public immutable collateral;
  uint256 public constant SEIZED = 1 ether;
  uint256 public constant REPAID = 100 ether;

  constructor(Id _marketId, address _loan, address _collateral) {
    MARKET_ID = _marketId;
    loan = _loan;
    collateral = _collateral;
  }

  function liquidate(MarketParams memory, address, uint256, uint256, bytes calldata data) external {
    ERC20Mock(collateral).transfer(msg.sender, SEIZED);
    ILiquidateCallback(msg.sender).onMoolahLiquidate(REPAID, data);
    ERC20Mock(loan).transferFrom(msg.sender, address(this), REPAID);
  }
}

/// @dev ERC20 that burns 1% of every transferFrom
contract FeeOnTransferMock is ERC20Mock {
  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    require(allowance[from][msg.sender] >= amount, "insufficient allowance");
    allowance[from][msg.sender] -= amount;
    require(balanceOf[from] >= amount, "insufficient balance");
    uint256 fee = amount / 100;
    balanceOf[from] -= amount;
    balanceOf[to] += amount - fee;
    totalSupply -= fee;
    emit Transfer(from, to, amount - fee);
    return true;
  }
}

/// @dev ERC20 whose fallback writes state, like WBNB's fallback -> deposit()
contract FallbackDepositMock is ERC20Mock {
  uint256 public fallbackCalls;

  fallback() external payable {
    fallbackCalls += 1;
  }

  receive() external payable {
    fallbackCalls += 1;
  }
}

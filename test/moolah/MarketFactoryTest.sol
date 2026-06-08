// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";
import { MarketFactory } from "moolah/MarketFactory.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MockBuyBack } from "./mocks/MockBuyBack.sol";
import { MockLiquidator } from "./mocks/MockLiquidator.sol";
import { MockListaAutoBuyBack } from "./mocks/MockListaAutoBuyBack.sol";
import { MockListaRevenueDistributor } from "./mocks/MockListaRevenueDistributor.sol";
import { Moolah } from "moolah/Moolah.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { MockProvider } from "./mocks/MockProvider.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { MockSmartProvider } from "./mocks/MockSmartProvider.sol";
import { RateCalculator, RateConfig } from "../../src/broker/RateCalculator.sol";
import { BrokerLiquidator } from "../../src/liquidator/BrokerLiquidator.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

contract MarketFactoryTest is Test {
  using MarketParamsLib for MarketParams;

  Moolah moolah;
  InterestRateModel irm;
  MarketFactory marketFactory;
  MockLiquidator liquidator;
  MockLiquidator publicLiquidator;
  MockListaRevenueDistributor listaRevenueDistributor;
  MockBuyBack buyBack;
  MockListaAutoBuyBack listaAutoBuyBack;
  MockProvider bnbProvider;
  MockProvider slisBNBProvider;
  ERC20Mock WBNB;
  ERC20Mock slisBNB;
  OracleMock oracle;
  RateCalculator rateCalculator;
  BrokerLiquidator brokerLiquidator;

  address admin;
  address manager;
  address pauser;
  address operator;
  address bot;
  uint256 minLoanValue;

  uint256 lltv80 = 0.8 ether;

  function setUp() public virtual {
    admin = makeAddr("admin");
    manager = makeAddr("manager");
    pauser = makeAddr("pauser");
    operator = makeAddr("operator");
    bot = makeAddr("bot");
    minLoanValue = 0;

    Moolah moolahImpl = new Moolah();
    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, minLoanValue)
    );
    moolah = Moolah(address(moolahProxy));

    InterestRateModel irmImpl = new InterestRateModel(address(moolah));
    ERC1967Proxy irmProxy = new ERC1967Proxy(
      address(irmImpl),
      abi.encodeWithSelector(irmImpl.initialize.selector, admin)
    );
    irm = InterestRateModel(address(irmProxy));

    RateCalculator rateCalculatorImpl = new RateCalculator();
    ERC1967Proxy rateCalculatorProxy = new ERC1967Proxy(
      address(rateCalculatorImpl),
      abi.encodeWithSelector(rateCalculatorImpl.initialize.selector, admin, manager, bot)
    );
    rateCalculator = RateCalculator(address(rateCalculatorProxy));

    BrokerLiquidator brokerLiquidatorImpl = new BrokerLiquidator(address(moolah));
    ERC1967Proxy brokerLiquidatorProxy = new ERC1967Proxy(
      address(brokerLiquidatorImpl),
      abi.encodeWithSelector(brokerLiquidatorImpl.initialize.selector, admin, manager, bot)
    );
    brokerLiquidator = BrokerLiquidator(payable(address(brokerLiquidatorProxy)));

    liquidator = new MockLiquidator();
    publicLiquidator = new MockLiquidator();
    listaRevenueDistributor = new MockListaRevenueDistributor();
    buyBack = new MockBuyBack();
    listaAutoBuyBack = new MockListaAutoBuyBack();

    WBNB = new ERC20Mock();
    slisBNB = new ERC20Mock();

    bnbProvider = new MockProvider(address(WBNB));
    slisBNBProvider = new MockProvider(address(slisBNB));
    oracle = new OracleMock();

    MarketFactory marketFactoryImpl = new MarketFactory(
      address(moolah),
      address(liquidator),
      address(publicLiquidator),
      address(listaRevenueDistributor),
      address(buyBack),
      address(listaAutoBuyBack),
      address(WBNB),
      address(slisBNB),
      address(bnbProvider),
      address(slisBNBProvider),
      address(rateCalculator),
      address(brokerLiquidator)
    );
    ERC1967Proxy marketFactoryProxy = new ERC1967Proxy(
      address(marketFactoryImpl),
      abi.encodeWithSelector(marketFactoryImpl.initialize.selector, admin, operator, pauser)
    );
    marketFactory = MarketFactory(address(marketFactoryProxy));

    vm.startPrank(manager);
    moolah.enableIrm(address(irm));
    moolah.enableLltv(lltv80);
    vm.stopPrank();

    vm.startPrank(admin);
    moolah.grantRole(moolah.OPERATOR(), address(marketFactory));
    moolah.grantRole(moolah.MANAGER(), address(marketFactory));
    rateCalculator.grantRole(rateCalculator.MANAGER(), address(marketFactory));
    brokerLiquidator.grantRole(brokerLiquidator.MANAGER(), address(marketFactory));
    vm.stopPrank();
  }

  function testCreateCommonMarket() public {
    ERC20Mock loanToken1 = new ERC20Mock();
    ERC20Mock collateralToken1 = new ERC20Mock();
    ERC20Mock loanToken2 = new ERC20Mock();
    ERC20Mock collateralToken2 = new ERC20Mock();

    oracle.setPrice(address(loanToken1), 1e8);
    oracle.setPrice(address(collateralToken1), 1e8);
    oracle.setPrice(address(loanToken2), 1e8);
    oracle.setPrice(address(collateralToken2), 1e8);

    MarketParams memory params1 = MarketParams({
      loanToken: address(loanToken1),
      collateralToken: address(collateralToken1),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    MarketParams memory params2 = MarketParams({
      loanToken: address(loanToken2),
      collateralToken: address(collateralToken2),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    MarketParams[] memory markets = new MarketParams[](2);
    markets[0] = params1;
    markets[1] = params2;

    address[] memory liquidators = new address[](3);
    liquidators[0] = address(liquidator);
    liquidators[1] = address(publicLiquidator);
    liquidators[2] = bot;

    address[] memory suppliers1 = new address[](2);
    suppliers1[0] = makeAddr("1");
    suppliers1[1] = makeAddr("2");

    address[] memory suppliers2 = new address[](1);
    suppliers2[0] = makeAddr("3");

    address[][] memory liquidatorWhitelist = new address[][](2);
    liquidatorWhitelist[0] = liquidators;
    liquidatorWhitelist[1] = liquidators;

    address[][] memory supplyWhitelist = new address[][](2);
    supplyWhitelist[0] = suppliers1;
    supplyWhitelist[1] = suppliers2;

    bool[] memory liquidatorMarketWhitelist = new bool[](2);
    liquidatorMarketWhitelist[0] = true;
    liquidatorMarketWhitelist[1] = true;

    bool[] memory liquidatorSmartProviders = new bool[](2);
    liquidatorSmartProviders[0] = false;
    liquidatorSmartProviders[1] = false;

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders
    );
    vm.stopPrank();

    assertEq(moolah.getLiquidationWhitelist(params1.id()), liquidators, "Liquidation whitelist mismatch for market 1");
    assertEq(moolah.getLiquidationWhitelist(params2.id()), liquidators, "Liquidation whitelist mismatch for market 2");
    assertTrue(
      liquidator.marketWhitelist(Id.unwrap(params1.id())),
      "Market whitelist not set for liquidator for market 1"
    );
    assertTrue(
      liquidator.marketWhitelist(Id.unwrap(params2.id())),
      "Market whitelist not set for liquidator for market 2"
    );
    assertTrue(
      liquidator.tokenWhitelist(address(params1.loanToken)),
      "Loan token whitelist not set for liquidator for market 1"
    );
    assertTrue(
      liquidator.tokenWhitelist(address(params1.collateralToken)),
      "Collateral token whitelist not set for liquidator for market 1"
    );
    assertTrue(
      liquidator.tokenWhitelist(address(params2.loanToken)),
      "Loan token whitelist not set for liquidator for market 2"
    );
    assertTrue(
      liquidator.tokenWhitelist(address(params2.collateralToken)),
      "Collateral token whitelist not set for liquidator for market 2"
    );
    assertTrue(
      listaRevenueDistributor.tokenWhitelist(address(params1.loanToken)),
      "Loan token whitelist not set for revenue distributor for market 1"
    );
    assertTrue(
      listaRevenueDistributor.tokenWhitelist(address(params2.loanToken)),
      "Loan token whitelist not set for revenue distributor for market 2"
    );
    assertTrue(
      buyBack.tokenInWhitelist(address(params1.loanToken)),
      "Loan token whitelist not set for buyback for market 1"
    );
    assertTrue(
      buyBack.tokenInWhitelist(address(params2.loanToken)),
      "Loan token whitelist not set for buyback for market 2"
    );
    assertTrue(
      listaAutoBuyBack.tokenWhitelist(address(params1.loanToken)),
      "Loan token whitelist not set for auto buyback for market 1"
    );
    assertTrue(
      listaAutoBuyBack.tokenWhitelist(address(params2.loanToken)),
      "Loan token whitelist not set for auto buyback for market 2"
    );
    assertEq(moolah.getWhiteList(params1.id()), suppliers1, "Supply whitelist mismatch for market 1");
    assertEq(moolah.getWhiteList(params2.id()), suppliers2, "Supply whitelist mismatch for market 2");
  }

  function testCreateSmartProviderMarket() public {
    ERC20Mock loanToken1 = new ERC20Mock();
    ERC20Mock collateralToken1 = new ERC20Mock();
    ERC20Mock loanToken2 = new ERC20Mock();
    ERC20Mock collateralToken2 = new ERC20Mock();

    ERC20Mock token0 = new ERC20Mock();
    ERC20Mock token1 = new ERC20Mock();

    MockSmartProvider smartProvider1 = new MockSmartProvider(address(collateralToken1));
    MockSmartProvider smartProvider2 = new MockSmartProvider(address(collateralToken2));

    smartProvider1.setPrice(address(loanToken1), 1e8);
    smartProvider1.setPrice(address(collateralToken1), 1e8);
    smartProvider2.setPrice(address(loanToken2), 1e8);
    smartProvider2.setPrice(address(collateralToken2), 1e8);
    smartProvider1.addToken(address(token0));
    smartProvider1.addToken(address(token1));
    smartProvider2.addToken(address(token0));
    smartProvider2.addToken(address(token1));

    MarketParams memory params1 = MarketParams({
      loanToken: address(loanToken1),
      collateralToken: address(collateralToken1),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(smartProvider1)
    });
    MarketParams memory params2 = MarketParams({
      loanToken: address(loanToken2),
      collateralToken: address(collateralToken2),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(smartProvider2)
    });

    MarketParams[] memory markets = new MarketParams[](2);
    markets[0] = params1;
    markets[1] = params2;

    address[][] memory liquidatorWhitelist = new address[][](2);
    address[][] memory supplyWhitelist = new address[][](2);

    bool[] memory liquidatorMarketWhitelist = new bool[](2);

    bool[] memory liquidatorSmartProviders = new bool[](2);
    liquidatorSmartProviders[0] = true;
    liquidatorSmartProviders[1] = true;

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders
    );
    vm.stopPrank();

    assertEq(
      moolah.providers(params1.id(), params1.collateralToken),
      address(smartProvider1),
      "Provider mismatch for market 1"
    );
    assertEq(
      moolah.providers(params2.id(), params2.collateralToken),
      address(smartProvider2),
      "Provider mismatch for market 2"
    );
    assertTrue(
      moolah.flashLoanTokenBlacklist(address(params1.collateralToken)),
      "Collateral token should be blacklisted for flash loan for market 1"
    );
    assertTrue(
      moolah.flashLoanTokenBlacklist(address(params2.collateralToken)),
      "Collateral token should be blacklisted for flash loan for market 2"
    );
    assertTrue(
      liquidator.smartProviders(address(smartProvider1)),
      "Smart provider whitelist not set for liquidator for market 1"
    );
    assertTrue(
      liquidator.smartProviders(address(smartProvider2)),
      "Smart provider whitelist not set for liquidator for market 2"
    );
    assertTrue(
      publicLiquidator.smartProviders(address(smartProvider1)),
      "Smart provider whitelist not set for public liquidator for market 1"
    );
    assertTrue(
      publicLiquidator.smartProviders(address(smartProvider2)),
      "Smart provider whitelist not set for public liquidator for market 2"
    );
    assertTrue(liquidator.tokenWhitelist(address(token0)), "Liquidator token whitelist not set for token0");
    assertTrue(liquidator.tokenWhitelist(address(token1)), "Liquidator token whitelist not set for token1");
  }

  function testCreateBNBMarket() public {
    ERC20Mock collateralToken = new ERC20Mock();
    MarketParams memory params = MarketParams({
      loanToken: address(WBNB),
      collateralToken: address(collateralToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    oracle.setPrice(address(collateralToken), 1e8);
    oracle.setPrice(address(WBNB), 1e8);

    MarketParams[] memory markets = new MarketParams[](1);
    markets[0] = params;

    address[] memory liquidators = new address[](3);
    liquidators[0] = address(liquidator);
    liquidators[1] = address(publicLiquidator);
    liquidators[2] = bot;

    address[] memory suppliers = new address[](0);

    address[][] memory liquidatorWhitelist = new address[][](1);
    liquidatorWhitelist[0] = liquidators;

    address[][] memory supplyWhitelist = new address[][](1);
    supplyWhitelist[0] = suppliers;

    bool[] memory liquidatorMarketWhitelist = new bool[](1);
    liquidatorMarketWhitelist[0] = true;

    bool[] memory liquidatorSmartProviders = new bool[](1);
    liquidatorSmartProviders[0] = false;

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders
    );
    vm.stopPrank();

    assertEq(moolah.providers(params.id(), address(WBNB)), address(bnbProvider), "Provider mismatch for BNB market");
  }

  function testCreateSlisBNBMarket() public {
    ERC20Mock loanToken = new ERC20Mock();
    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(slisBNB),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(slisBNB), 1e8);
    MarketParams[] memory markets = new MarketParams[](1);
    markets[0] = params;

    address[] memory liquidators = new address[](3);
    liquidators[0] = address(liquidator);
    liquidators[1] = address(publicLiquidator);
    liquidators[2] = bot;

    address[] memory suppliers = new address[](0);

    address[][] memory liquidatorWhitelist = new address[][](1);
    liquidatorWhitelist[0] = liquidators;

    address[][] memory supplyWhitelist = new address[][](1);
    supplyWhitelist[0] = suppliers;

    bool[] memory liquidatorMarketWhitelist = new bool[](1);
    liquidatorMarketWhitelist[0] = true;

    bool[] memory liquidatorSmartProviders = new bool[](1);
    liquidatorSmartProviders[0] = false;

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders
    );
    vm.stopPrank();

    assertEq(
      moolah.providers(params.id(), address(slisBNB)),
      address(slisBNBProvider),
      "Provider mismatch for BNB market"
    );
  }

  function testCreateFixedTermMarket() public {
    address relayer = makeAddr("relayer");
    uint256 ratePerSecond = 1000000000195993755570992534;
    uint256 maxRatePerSecond = 1000000008319516284844716199;
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();
    LendingBroker broker = newLendingBroker(relayer);

    MarketFactory.FixedTermMarketParams memory params = MarketFactory.FixedTermMarketParams({
      broker: address(broker),
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      irm: address(irm),
      lltv: lltv80,
      ratePerSecond: ratePerSecond,
      maxRatePerSecond: maxRatePerSecond
    });
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    vm.startPrank(admin);
    broker.grantRole(broker.MANAGER(), address(marketFactory));
    vm.stopPrank();

    vm.startPrank(operator);
    Id id = marketFactory.createFixedTermMarket(params);
    vm.stopPrank();

    assertEq(Id.unwrap(id), Id.unwrap(broker.MARKET_ID()), "Market ID mismatch between broker and market factory");
    assertEq(moolah.brokers(id), address(broker), "Broker not set for market");
    assertTrue(moolah.isLiquidationWhitelist(id, address(broker)), "Broker should be in liquidation whitelist");
    assertEq(
      broker.getLiquidationWhitelist()[0],
      address(brokerLiquidator),
      "Liquidation whitelist mismatch for broker"
    );
    assertEq(
      brokerLiquidator.brokerToMarketId(address(broker)),
      Id.unwrap(id),
      "Market ID mismatch in broker liquidator"
    );
  }

  function newLendingBroker(address replayer) private returns (LendingBroker) {
    LendingBroker lendingBrokerImpl = new LendingBroker(address(moolah), replayer, address(oracle), address(0));
    ERC1967Proxy lendingBrokerProxy = new ERC1967Proxy(
      address(lendingBrokerImpl),
      abi.encodeWithSelector(
        lendingBrokerImpl.initialize.selector,
        admin,
        manager,
        bot,
        pauser,
        address(rateCalculator),
        100
      )
    );

    return LendingBroker(payable(address(lendingBrokerProxy)));
  }
}

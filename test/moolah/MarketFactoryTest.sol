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
import { MockBrokerInterestRelayer } from "./mocks/MockBrokerInterestRelayer.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { MockSmartProvider } from "./mocks/MockSmartProvider.sol";
import { RateCalculator, RateConfig } from "../../src/broker/RateCalculator.sol";
import { BrokerLiquidator } from "../../src/liquidator/BrokerLiquidator.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { LiquidationVault } from "../../src/liquidator/LiquidationVault.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";
import { V3Liquidator } from "../../src/liquidator/V3Liquidator.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { MockV3Adapter, MockV3Share, MockV3Oracle, MockV3LiquidatorView } from "./mocks/MockV3Provider.sol";
import { V3MarketParams } from "moolah/libraries/V3MarketLib.sol";

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
  LiquidationVault liquidationVault;
  StockOracleSwitch stockOracleSwitch;

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

    LiquidationVault liquidationVaultImpl = new LiquidationVault();
    ERC1967Proxy liquidationVaultProxy = new ERC1967Proxy(
      address(liquidationVaultImpl),
      abi.encodeWithSelector(liquidationVaultImpl.initialize.selector, admin, manager, pauser, bot)
    );
    liquidationVault = LiquidationVault(payable(address(liquidationVaultProxy)));

    StockOracleSwitch stockOracleSwitchImpl = new StockOracleSwitch();
    ERC1967Proxy stockOracleSwitchProxy = new ERC1967Proxy(
      address(stockOracleSwitchImpl),
      abi.encodeWithSelector(stockOracleSwitchImpl.initialize.selector, admin, manager, bot, pauser)
    );
    stockOracleSwitch = StockOracleSwitch(address(stockOracleSwitchProxy));

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
      address(slisBNBProvider)
    );
    ERC1967Proxy marketFactoryProxy = new ERC1967Proxy(
      address(marketFactoryImpl),
      abi.encodeWithSelector(marketFactoryImpl.initialize.selector, admin, operator, pauser)
    );
    marketFactory = MarketFactory(address(marketFactoryProxy));

    // Set storage-based variables via setter
    vm.startPrank(admin);
    marketFactory.setRateCalculator(address(rateCalculator));
    marketFactory.setBrokerLiquidator(address(brokerLiquidator));
    marketFactory.setLiquidationVault(address(liquidationVault));
    marketFactory.setStockOracleSwitch(address(stockOracleSwitch));
    vm.stopPrank();

    vm.startPrank(manager);
    moolah.enableIrm(address(irm));
    moolah.enableLltv(lltv80);
    vm.stopPrank();

    vm.startPrank(admin);
    moolah.grantRole(moolah.OPERATOR(), address(marketFactory));
    moolah.grantRole(moolah.MANAGER(), address(marketFactory));
    rateCalculator.grantRole(rateCalculator.MANAGER(), address(marketFactory));
    brokerLiquidator.grantRole(brokerLiquidator.MANAGER(), address(marketFactory));
    liquidationVault.grantRole(liquidationVault.MANAGER(), address(marketFactory));
    stockOracleSwitch.grantRole(stockOracleSwitch.MANAGER(), address(marketFactory));
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

    bool[] memory stockCollaterals = new bool[](markets.length);

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders,
      stockCollaterals
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

    bool[] memory stockCollaterals = new bool[](markets.length);

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders,
      stockCollaterals
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
    assertTrue(liquidationVault.tokenWhitelist(address(token0)), "token0 not whitelisted in vault");
    assertTrue(liquidationVault.tokenWhitelist(address(token1)), "token1 not whitelisted in vault");
    // the pair legs and the loan tokens are whitelisted across the whole suite ...
    assertSuiteWhitelisted(address(token0), true);
    assertSuiteWhitelisted(address(token1), true);
    assertSuiteWhitelisted(address(loanToken1), true);
    assertSuiteWhitelisted(address(loanToken2), true);
    // ... but the LP itself must never be sellable/collectable by the vault, and must be
    // reflow-blacklisted on both liquidators that reflow into it
    assertSmartLpGated(address(collateralToken1));
    assertSmartLpGated(address(collateralToken2));
    assertSmartProviderRegistered(address(smartProvider1));
    assertSmartProviderRegistered(address(smartProvider2));
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

    bool[] memory stockCollaterals = new bool[](markets.length);

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders,
      stockCollaterals
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

    bool[] memory stockCollaterals = new bool[](markets.length);

    vm.startPrank(operator);
    marketFactory.batchCreateMarkets(
      markets,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProviders,
      stockCollaterals
    );
    vm.stopPrank();

    assertEq(
      moolah.providers(params.id(), address(slisBNB)),
      address(slisBNBProvider),
      "Provider mismatch for BNB market"
    );
  }

  function testCreateFixedTermMarket() public {
    uint256 ratePerSecond = 1000000000195993755570992534;
    uint256 maxRatePerSecond = 1000000008319516284844716199;
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();
    MockBrokerInterestRelayer relayer = newRelayer(address(loanToken));
    LendingBroker broker = newLendingBroker(address(relayer));

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
    Id id = marketFactory.batchCreateFixedTermMarkets(asBatch(params))[0];
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
    assertTrue(liquidationVault.tokenWhitelist(address(loanToken)), "loan token not whitelisted in vault");
    assertTrue(liquidationVault.tokenWhitelist(address(collateralToken)), "collateral token not whitelisted in vault");
    // a broker market is liquidated via BrokerLiquidator, but the token whitelist is kept uniform
    assertSuiteWhitelisted(address(loanToken), true);
    assertSuiteWhitelisted(address(collateralToken), true);

    // the factory registers the broker on its own relayer
    address[] memory registered = relayer.getBrokers();
    assertEq(registered.length, 1, "broker not registered on relayer");
    assertEq(registered[0], address(broker), "wrong broker registered on relayer");

    assertEq(moolah.providers(id, address(loanToken)), address(0), "unexpected provider on loan token");
  }

  function testCreateStockMarket() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock stockToken = new ERC20Mock();

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(stockToken), 1e8);

    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(stockToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    vm.prank(operator);
    marketFactory.createMarket(params, new address[](0), new address[](0), true, false, true);

    assertTrue(stockOracleSwitch.registered(address(stockToken)), "stock not registered in switch");
    assertTrue(stockOracleSwitch.enabled(address(stockToken)), "stock not enabled in switch");
    // the loan token is not a managed stock: it must stay unregistered (passthrough in the oracle)
    assertFalse(stockOracleSwitch.registered(address(loanToken)), "loan token should not be registered");
    // global market switch is MANAGER-owned and untouched by the factory, so the stock is still gated
    assertFalse(stockOracleSwitch.globalEnabled(), "factory must not open the global market switch");
    assertFalse(stockOracleSwitch.isEnabled(address(stockToken)), "stock tradable before global open");

    vm.prank(manager);
    stockOracleSwitch.setGlobal(true);
    assertTrue(stockOracleSwitch.isEnabled(address(stockToken)), "stock not tradable after global open");
  }

  /// @dev setStock reverts (AlreadySet) on a no-op, so an already-registered stock must be skipped.
  function testCreateStockMarketAlreadyRegistered() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock stockToken = new ERC20Mock();

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(stockToken), 1e8);

    // stock already registered (e.g. a second market on the same collateral), and currently closed
    vm.prank(manager);
    stockOracleSwitch.setStock(address(stockToken), true);
    vm.prank(bot);
    stockOracleSwitch.close(address(stockToken));

    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(stockToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    vm.prank(operator);
    marketFactory.createMarket(params, new address[](0), new address[](0), true, false, true);

    assertTrue(stockOracleSwitch.registered(address(stockToken)), "stock should stay registered");
    // creating a market must not re-open a stock that ops deliberately closed
    assertFalse(stockOracleSwitch.enabled(address(stockToken)), "closed stock must not be reopened");
  }

  function testCreateStockMarketRevertsWhenSwitchNotSet() public {
    MarketFactory factory = newMarketFactory();
    vm.startPrank(admin);
    moolah.grantRole(moolah.OPERATOR(), address(factory));
    moolah.grantRole(moolah.MANAGER(), address(factory));
    vm.stopPrank();

    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock stockToken = new ERC20Mock();
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(stockToken), 1e8);

    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(stockToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    vm.prank(operator);
    vm.expectRevert("StockOracleSwitch not set");
    factory.createMarket(params, new address[](0), new address[](0), true, false, true);
  }

  function testCreateMarketWhitelistsLiquidationVaultTokens() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    vm.prank(operator);
    marketFactory.createMarket(params, new address[](0), new address[](0), true, false, false);

    // uniform across Liquidator / BrokerLiquidator / LiquidationVault
    assertSuiteWhitelisted(address(loanToken), true);
    assertSuiteWhitelisted(address(collateralToken), true);
  }

  /// @dev setTokenWhitelist reverts (WhitelistSameStatus) on a no-op, so an already-whitelisted token
  ///      must be skipped — otherwise a second market sharing the loan token bricks creation.
  function testCreateMarketVaultWhitelistIdempotent() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken1 = new ERC20Mock();
    ERC20Mock collateralToken2 = new ERC20Mock();

    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken1), 1e8);
    oracle.setPrice(address(collateralToken2), 1e8);

    vm.prank(manager);
    liquidationVault.setTokenWhitelist(address(loanToken), true);

    MarketParams memory params1 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken1),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });
    MarketParams memory params2 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken2),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    vm.startPrank(operator);
    marketFactory.createMarket(params1, new address[](0), new address[](0), true, false, false);
    marketFactory.createMarket(params2, new address[](0), new address[](0), true, false, false);
    vm.stopPrank();

    assertTrue(liquidationVault.tokenWhitelist(address(collateralToken1)), "collateral 1 not whitelisted");
    assertTrue(liquidationVault.tokenWhitelist(address(collateralToken2)), "collateral 2 not whitelisted");
  }

  function testCreateMarketSkipsVaultWhenUnset() public {
    MarketFactory factory = newMarketFactory();
    vm.startPrank(admin);
    moolah.grantRole(moolah.OPERATOR(), address(factory));
    moolah.grantRole(moolah.MANAGER(), address(factory));
    vm.stopPrank();

    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);

    MarketParams memory params = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      lltv: lltv80,
      irm: address(irm),
      oracle: address(oracle)
    });

    // no liquidationVault wired: creation still succeeds, just without vault whitelisting
    vm.prank(operator);
    factory.createMarket(params, new address[](0), new address[](0), true, false, false);

    assertFalse(liquidationVault.tokenWhitelist(address(loanToken)), "vault should be untouched");
  }

  function testSettersOnlyAdmin() public {
    address rando = makeAddr("rando");

    vm.startPrank(rando);
    vm.expectRevert();
    marketFactory.setLiquidationVault(address(liquidationVault));
    vm.expectRevert();
    marketFactory.setStockOracleSwitch(address(stockOracleSwitch));
    vm.stopPrank();

    vm.startPrank(admin);
    vm.expectRevert("ZeroAddress");
    marketFactory.setLiquidationVault(address(0));
    vm.expectRevert("ZeroAddress");
    marketFactory.setStockOracleSwitch(address(0));
    vm.stopPrank();
  }

  /// @dev `token` must be whitelisted on Liquidator + BrokerLiquidator, and on the vault iff `inVault`.
  function assertSuiteWhitelisted(address token, bool inVault) private view {
    assertTrue(liquidator.tokenWhitelist(token), "token not whitelisted on liquidator");
    assertTrue(brokerLiquidator.tokenWhitelist(token), "token not whitelisted on brokerLiquidator");
    assertEq(liquidationVault.tokenWhitelist(token), inVault, "vault whitelist state mismatch");
  }

  /// @dev A smart-collateral LP: never vault-whitelisted, always reflow-blacklisted on both liquidators.
  function assertSmartLpGated(address lp) private view {
    assertFalse(liquidationVault.tokenWhitelist(lp), "smart LP must not be whitelisted in vault");
    assertTrue(liquidator.reflowBlacklist(lp), "smart LP not reflow-blacklisted on liquidator");
    assertTrue(brokerLiquidator.reflowBlacklist(lp), "smart LP not reflow-blacklisted on brokerLiquidator");
  }

  /// @dev A smart provider must be registered on every liquidator that can liquidate through it.
  function assertSmartProviderRegistered(address provider) private view {
    assertTrue(liquidator.smartProviders(provider), "provider not set on liquidator");
    assertTrue(publicLiquidator.smartProviders(provider), "provider not set on publicLiquidator");
    assertTrue(brokerLiquidator.smartProviders(provider), "provider not set on brokerLiquidator");
  }

  /// @dev A MarketFactory proxy with neither liquidationVault nor stockOracleSwitch wired.
  function newMarketFactory() private returns (MarketFactory) {
    MarketFactory impl = new MarketFactory(
      address(moolah),
      address(liquidator),
      address(publicLiquidator),
      address(listaRevenueDistributor),
      address(buyBack),
      address(listaAutoBuyBack),
      address(WBNB),
      address(slisBNB),
      address(bnbProvider),
      address(slisBNBProvider)
    );
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, operator, pauser)
    );
    return MarketFactory(address(proxy));
  }

  function testFixedTermMarketRegistersBNBProvider() public {
    ERC20Mock collateralToken = new ERC20Mock();
    MockBrokerInterestRelayer relayer = newRelayer(address(WBNB));
    LendingBroker broker = newLendingBroker(address(relayer));

    Id id = createFixedTerm(broker, address(WBNB), address(collateralToken));

    assertEq(moolah.providers(id, address(WBNB)), address(bnbProvider), "BNBProvider not registered");
  }

  function testFixedTermMarketRegistersBNBProviderForNativeCollateral() public {
    ERC20Mock loanToken = new ERC20Mock();
    MockBrokerInterestRelayer relayer = newRelayer(address(loanToken));
    LendingBroker broker = newLendingBroker(address(relayer));

    Id id = createFixedTerm(broker, address(loanToken), address(WBNB));

    assertEq(moolah.providers(id, address(WBNB)), address(bnbProvider), "BNBProvider not registered");
  }

  function testFixedTermMarketSkipsRelayerWhenAlreadyRegistered() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();
    MockBrokerInterestRelayer relayer = newRelayer(address(loanToken));
    LendingBroker broker = newLendingBroker(address(relayer));

    // pre-register by hand: addBroker needs LOAN_TOKEN, so set the market id first
    bytes32 brokerManager = broker.MANAGER();
    vm.prank(admin);
    broker.grantRole(brokerManager, address(this));
    Id preId = fixedTermId(broker, address(loanToken), address(collateralToken));
    createRawMarket(address(loanToken), address(collateralToken), address(broker));
    broker.setMarketId(preId);
    relayer.setManager(address(this), true);
    relayer.addBroker(address(broker));
    assertEq(relayer.getBrokers().length, 1, "pre-condition");

    LendingBroker broker2 = newLendingBroker(address(relayer));
    ERC20Mock collateral2 = new ERC20Mock();
    createFixedTerm(broker2, address(loanToken), address(collateral2));

    address[] memory registered = relayer.getBrokers();
    assertEq(registered.length, 2, "second broker not registered");
    assertEq(registered[1], address(broker2), "wrong broker registered");
  }

  function testFixedTermMarketRevertsWhenFactoryLacksRelayerManager() public {
    ERC20Mock loanToken = new ERC20Mock();
    ERC20Mock collateralToken = new ERC20Mock();
    MockBrokerInterestRelayer relayer = new MockBrokerInterestRelayer(address(loanToken)); // no grant
    LendingBroker broker = newLendingBroker(address(relayer));

    MarketFactory.FixedTermMarketParams memory params = fixedTermParams(
      broker,
      address(loanToken),
      address(collateralToken)
    );
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);
    bytes32 brokerManager = broker.MANAGER();
    vm.prank(admin);
    broker.grantRole(brokerManager, address(marketFactory));

    MarketFactory.FixedTermMarketParams[] memory batch = asBatch(params);
    vm.prank(operator);
    vm.expectRevert(bytes("relayer/not-manager"));
    marketFactory.batchCreateFixedTermMarkets(batch);

    assertEq(Id.unwrap(broker.MARKET_ID()), bytes32(0), "market id should not be set");
  }

  // ---------------------------------------------------------------- helpers

  function fixedTermParams(
    LendingBroker broker,
    address loanToken,
    address collateralToken
  ) private view returns (MarketFactory.FixedTermMarketParams memory) {
    return
      MarketFactory.FixedTermMarketParams({
        broker: address(broker),
        loanToken: loanToken,
        collateralToken: collateralToken,
        irm: address(irm),
        lltv: lltv80,
        ratePerSecond: 1000000000195993755570992534,
        maxRatePerSecond: 1000000008319516284844716199
      });
  }

  function fixedTermId(LendingBroker broker, address loanToken, address collateralToken) private view returns (Id) {
    return
      MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: address(broker),
        irm: address(irm),
        lltv: lltv80
      }).id();
  }

  function createRawMarket(address loanToken, address collateralToken, address brokerAsOracle) private {
    oracle.setPrice(loanToken, 1e8);
    oracle.setPrice(collateralToken, 1e8);
    vm.prank(address(marketFactory));
    moolah.createMarket(
      MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: brokerAsOracle,
        irm: address(irm),
        lltv: lltv80
      })
    );
  }

  function createFixedTerm(LendingBroker broker, address loanToken, address collateralToken) private returns (Id) {
    oracle.setPrice(loanToken, 1e8);
    oracle.setPrice(collateralToken, 1e8);
    bytes32 brokerManager = broker.MANAGER();
    vm.prank(admin);
    broker.grantRole(brokerManager, address(marketFactory));
    MarketFactory.FixedTermMarketParams[] memory batch = asBatch(fixedTermParams(broker, loanToken, collateralToken));
    vm.prank(operator);
    return marketFactory.batchCreateFixedTermMarkets(batch)[0];
  }

  function asBatch(
    MarketFactory.FixedTermMarketParams memory params
  ) private pure returns (MarketFactory.FixedTermMarketParams[] memory batch) {
    batch = new MarketFactory.FixedTermMarketParams[](1);
    batch[0] = params;
  }

  function newRelayer(address loanToken) private returns (MockBrokerInterestRelayer) {
    MockBrokerInterestRelayer relayer = new MockBrokerInterestRelayer(loanToken);
    relayer.setManager(address(marketFactory), true);
    return relayer;
  }

  function newLendingBroker(address replayer) private returns (LendingBroker) {
    LendingBroker lendingBrokerImpl = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy lendingBrokerProxy = new ERC1967Proxy(
      address(lendingBrokerImpl),
      abi.encodeWithSelector(
        lendingBrokerImpl.initialize.selector,
        admin,
        manager,
        bot,
        pauser,
        address(rateCalculator),
        100,
        replayer,
        address(oracle)
      )
    );

    return LendingBroker(payable(address(lendingBrokerProxy)));
  }

  /* ───────────────────────── V3 LP share markets ───────────────────────── */

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  function _newV3Liquidator() internal returns (V3Liquidator) {
    return _newV3Liquidator(address(0));
  }

  function _newV3Liquidator(address fundSource) internal returns (V3Liquidator v3Liq) {
    V3Liquidator impl = new V3Liquidator(address(moolah));
    v3Liq = V3Liquidator(
      payable(
        address(
          new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(impl.initialize.selector, admin, manager, bot, fundSource)
          )
        )
      )
    );
  }

  function _setUpV3() internal returns (V3Liquidator v3Liq) {
    v3Liq = _newV3Liquidator();
    vm.startPrank(admin);
    v3Liq.grantRole(v3Liq.MANAGER(), address(marketFactory));
    marketFactory.setV3Liquidator(address(v3Liq));
    vm.stopPrank();
  }

  function _newV3Share(address token0, address token1) internal returns (MockV3Share share, MockV3Oracle v3Oracle) {
    MockV3Adapter adapter = new MockV3Adapter();
    share = new MockV3Share(address(moolah), address(adapter), token0, token1, address(WBNB), address(oracle));
    adapter.setProvider(address(share));
    share.setDepositWhitelistEnabled(true);
    v3Oracle = new MockV3Oracle(address(share), address(oracle));
  }

  /// @dev slisBNB-like share: token0 = LST, token1 = WBNB (the wrapped native).
  function _newV3Share(address token0) internal returns (MockV3Share, MockV3Oracle) {
    return _newV3Share(token0, address(WBNB));
  }

  function _v3Market(
    address loan,
    address share,
    address v3Oracle,
    address[] memory extra
  ) internal view returns (V3MarketParams memory m) {
    m.params = MarketParams({
      loanToken: loan,
      collateralToken: share,
      oracle: v3Oracle,
      irm: address(irm),
      lltv: lltv80
    });
    m.extraLiquidators = extra;
  }

  function _createV3(V3MarketParams memory m) internal {
    V3MarketParams[] memory ms = new V3MarketParams[](1);
    ms[0] = m;
    vm.prank(operator);
    marketFactory.batchCreateV3Markets(ms);
  }

  function _noExtra() internal pure returns (address[] memory) {
    return new address[](0);
  }

  function testCreateV3Market_wiresShareMarket() public {
    V3Liquidator v3Liq = _setUpV3();
    ERC20Mock lst = new ERC20Mock();
    ERC20Mock loan = new ERC20Mock();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(lst));
    address[] memory extra = new address[](1);
    extra[0] = bot;
    V3MarketParams memory m = _v3Market(address(loan), address(share), address(v3Oracle), extra);
    _createV3(m);
    Id id = m.params.id();

    assertEq(moolah.providers(id, address(share)), address(share), "share is its own provider");
    assertTrue(moolah.flashLoanTokenBlacklist(address(share)), "share flash-loan blacklisted");
    address[] memory wl = moolah.getLiquidationWhitelist(id);
    assertEq(wl.length, 2);
    assertEq(wl[0], address(v3Liq));
    assertEq(wl[1], bot);
    assertTrue(v3Liq.marketWhitelist(Id.unwrap(id)));
    assertTrue(v3Liq.v3Providers(address(share)));
    assertTrue(v3Liq.reflowBlacklist(address(share)), "share reflow-blacklisted");
    assertEq(marketFactory.v3OracleOf(address(share)), address(v3Oracle), "oracle pinned");

    // loan + legs + native on the V3Liquidator; legs + native on the vault
    assertTrue(v3Liq.tokenWhitelist(address(loan)));
    assertTrue(v3Liq.tokenWhitelist(address(lst)));
    assertTrue(v3Liq.tokenWhitelist(address(WBNB)));
    assertTrue(v3Liq.tokenWhitelist(BNB_ADDRESS));
    assertTrue(liquidationVault.tokenWhitelist(address(lst)));
    assertTrue(liquidationVault.tokenWhitelist(address(WBNB)));
    assertTrue(liquidationVault.tokenWhitelist(BNB_ADDRESS));
    assertTrue(liquidationVault.tokenWhitelist(address(loan)));
    // the share itself is whitelisted nowhere, and the generic liquidator is not wired to the market
    assertFalse(liquidationVault.tokenWhitelist(address(share)));
    assertFalse(v3Liq.tokenWhitelist(address(share)));
    assertFalse(liquidator.tokenWhitelist(address(share)));
    assertFalse(liquidator.marketWhitelist(Id.unwrap(id)));
    assertTrue(listaRevenueDistributor.tokenWhitelist(address(loan)));
  }

  function testCreateV3Market_shareWithoutNativeLeg() public {
    V3Liquidator v3Liq = _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()), address(new ERC20Mock()));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));
    assertFalse(v3Liq.tokenWhitelist(BNB_ADDRESS), "no native leg, no native whitelist");
    assertFalse(liquidationVault.tokenWhitelist(BNB_ADDRESS));
  }

  function testCreateV3Market_toleratesPreconfiguredSwitches() public {
    V3Liquidator v3Liq = _setUpV3();
    ERC20Mock lst = new ERC20Mock();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(lst));
    vm.startPrank(manager);
    moolah.setFlashLoanTokenBlacklist(address(share), true);
    v3Liq.setV3ProviderWhitelist(address(share), true);
    v3Liq.setReflowBlacklist(address(share), true);
    v3Liq.setTokenWhitelist(address(lst), true);
    v3Liq.setTokenWhitelist(BNB_ADDRESS, true);
    liquidationVault.setTokenWhitelist(address(WBNB), true);
    vm.stopPrank();

    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));
    assertTrue(v3Liq.v3Providers(address(share)));
  }

  function testCreateV3Market_secondMarketRewiresProviderSwitches() public {
    V3Liquidator v3Liq = _setUpV3();
    ERC20Mock lst = new ERC20Mock();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(lst));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    // incident response: MANAGER pauses the provider and delists a leg
    vm.startPrank(manager);
    v3Liq.setV3ProviderWhitelist(address(share), false);
    v3Liq.setReflowBlacklist(address(share), false);
    v3Liq.setTokenWhitelist(address(lst), false);
    liquidationVault.setTokenWhitelist(address(lst), false);
    vm.stopPrank();

    V3MarketParams memory m2 = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    _createV3(m2);

    // like a smart provider, a new market turns the switches back on
    assertTrue(v3Liq.v3Providers(address(share)), "provider re-enabled");
    assertTrue(v3Liq.reflowBlacklist(address(share)), "reflow blacklist restored");
    assertTrue(v3Liq.tokenWhitelist(address(lst)), "leg re-listed on the liquidator");
    assertTrue(liquidationVault.tokenWhitelist(address(lst)), "leg re-listed on the vault");
    assertEq(moolah.providers(m2.params.id(), address(share)), address(share), "second market still wired");
    assertTrue(v3Liq.marketWhitelist(Id.unwrap(m2.params.id())));
  }

  function testCreateV3Market_replacementLiquidatorGetsWired() public {
    V3Liquidator first = _setUpV3();
    ERC20Mock lst = new ERC20Mock();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(lst));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    V3Liquidator second = _setUpV3();
    assertTrue(address(second) != address(first));
    V3MarketParams memory m2 = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    _createV3(m2);

    assertTrue(second.v3Providers(address(share)), "new liquidator knows the provider");
    assertTrue(second.reflowBlacklist(address(share)));
    assertTrue(second.tokenWhitelist(address(lst)));
    assertTrue(second.tokenWhitelist(BNB_ADDRESS));
    assertTrue(second.marketWhitelist(Id.unwrap(m2.params.id())));
  }

  function testCreateV3Market_twoMarketsSameShareInOneBatch() public {
    V3Liquidator v3Liq = _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    V3MarketParams[] memory ms = new V3MarketParams[](2);
    ms[0] = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    ms[1] = _v3Market(address(WBNB), address(share), address(v3Oracle), _noExtra());
    vm.prank(operator);
    marketFactory.batchCreateV3Markets(ms);

    for (uint256 i = 0; i < 2; i++) {
      Id id = ms[i].params.id();
      assertEq(moolah.providers(id, address(share)), address(share));
      assertTrue(v3Liq.marketWhitelist(Id.unwrap(id)));
      assertEq(moolah.getLiquidationWhitelist(id)[0], address(v3Liq));
    }
    assertEq(moolah.providers(ms[1].params.id(), address(WBNB)), address(bnbProvider), "BNBProvider on the WBNB loan");
  }

  function testCreateV3Market_pinsTheFirstOracle() public {
    _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    // a second, equally self-consistent oracle proxy for the same share
    MockV3Oracle other = new MockV3Oracle(address(share), address(oracle));
    V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(other), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Oracle.selector);
    _createV3(m);
  }

  function testCreateV3Market_rejectsForeignOracle() public {
    _setUpV3();
    (MockV3Share share, ) = _newV3Share(address(new ERC20Mock()));
    address loan = address(new ERC20Mock());

    MockV3Oracle wrongShare = new MockV3Oracle(makeAddr("otherShare"), address(oracle));
    V3MarketParams memory m1 = _v3Market(loan, address(share), address(wrongShare), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Oracle.selector);
    _createV3(m1);

    MockV3Oracle wrongFeed = new MockV3Oracle(address(share), makeAddr("otherResilientOracle"));
    V3MarketParams memory m2 = _v3Market(loan, address(share), address(wrongFeed), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Oracle.selector);
    _createV3(m2);
  }

  function testCreateV3Market_rejectsUnwiredShare() public {
    _setUpV3();
    address loan = address(new ERC20Mock());

    (MockV3Share unwired, MockV3Oracle o1) = _newV3Share(address(new ERC20Mock()));
    MockV3Adapter(unwired.ADAPTER()).setProvider(address(0));
    V3MarketParams memory m1 = _v3Market(loan, address(unwired), address(o1), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Share.selector);
    _createV3(m1);

    (MockV3Share notShare, MockV3Oracle o2) = _newV3Share(address(new ERC20Mock()));
    notShare.setTokenOverride(makeAddr("lp"));
    V3MarketParams memory m2 = _v3Market(loan, address(notShare), address(o2), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Share.selector);
    _createV3(m2);

    MockV3Adapter adapter = new MockV3Adapter();
    MockV3Share otherMoolah = new MockV3Share(
      makeAddr("otherMoolah"),
      address(adapter),
      address(new ERC20Mock()),
      address(WBNB),
      address(WBNB),
      address(oracle)
    );
    adapter.setProvider(address(otherMoolah));
    otherMoolah.setDepositWhitelistEnabled(true);
    MockV3Oracle o3 = new MockV3Oracle(address(otherMoolah), address(oracle));
    V3MarketParams memory m3 = _v3Market(loan, address(otherMoolah), address(o3), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Share.selector);
    _createV3(m3);
  }

  function testCreateV3Market_requiresDepositGuard() public {
    _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    share.setDepositWhitelistEnabled(false);
    V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    vm.expectRevert(MarketFactory.V3DepositUnguarded.selector);
    _createV3(m);

    share.setTotalSupply(1e18); // seeded
    _createV3(m);
    assertEq(moolah.providers(m.params.id(), address(share)), address(share));
  }

  function testCreateV3Market_rejectsUnsafeExtraLiquidators() public {
    V3Liquidator v3Liq = _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    address[5] memory bad = [
      address(0),
      address(liquidator),
      address(publicLiquidator),
      address(brokerLiquidator),
      address(v3Liq)
    ];
    for (uint256 i = 0; i < bad.length; i++) {
      address[] memory extra = new address[](1);
      extra[0] = bad[i];
      V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), extra);
      vm.expectRevert(MarketFactory.InvalidLiquidator.selector);
      _createV3(m);
    }
  }

  function testCreateV3Market_requiresReflowIntoTheVault() public {
    V3Liquidator v3Liq = _setUpV3();
    vm.prank(manager);
    liquidationVault.setLiquidator(address(v3Liq), true);
    vm.prank(manager);
    v3Liq.setFundSource(address(liquidationVault));
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    // the factory's vault moves while the liquidator still reflows into the old one
    vm.prank(admin);
    marketFactory.setLiquidationVault(makeAddr("newVault"));
    V3MarketParams memory m2 = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Liquidator.selector);
    _createV3(m2);
  }

  function testCreateV3Market_requiresVaultRegistration() public {
    // a fundSource set at initialize skips setFundSource's registration check
    V3Liquidator v3Liq = _newV3Liquidator(address(liquidationVault));
    vm.startPrank(admin);
    v3Liq.grantRole(v3Liq.MANAGER(), address(marketFactory));
    marketFactory.setV3Liquidator(address(v3Liq));
    vm.stopPrank();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Liquidator.selector);
    _createV3(m);

    vm.prank(manager);
    liquidationVault.setLiquidator(address(v3Liq), true);
    _createV3(m);

    // deregistered later: the next market is refused
    vm.prank(manager);
    liquidationVault.setLiquidator(address(v3Liq), false);
    V3MarketParams memory m2 = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    vm.expectRevert(MarketFactory.InvalidV3Liquidator.selector);
    _createV3(m2);
  }

  function testCreateV3Market_accessPauseAndLiquidatorUnset() public {
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());

    vm.expectRevert(MarketFactory.V3LiquidatorNotSet.selector);
    _createV3(m);

    _setUpV3();
    V3MarketParams[] memory ms = new V3MarketParams[](1);
    ms[0] = m;
    vm.expectRevert();
    marketFactory.batchCreateV3Markets(ms); // not OPERATOR

    vm.prank(pauser);
    marketFactory.pause();
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    _createV3(m);
  }

  function testCreateV3Market_revertsAtomicallyWithoutV3LiquidatorRole() public {
    V3Liquidator v3Liq = _newV3Liquidator();
    vm.prank(admin);
    marketFactory.setV3Liquidator(address(v3Liq)); // MANAGER not granted to the factory

    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    V3MarketParams memory m = _v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra());
    vm.expectRevert();
    _createV3(m);
    (, , , , uint128 lastUpdate, ) = moolah.market(m.params.id());
    assertEq(lastUpdate, 0, "no half-configured market");
    assertEq(marketFactory.v3OracleOf(address(share)), address(0), "nothing pinned");
  }

  function testCreateMarket_rejectsRegisteredV3Share() public {
    _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    MarketParams memory p = MarketParams({
      loanToken: address(new ERC20Mock()),
      collateralToken: address(share),
      oracle: address(v3Oracle),
      irm: address(irm),
      lltv: lltv80
    });
    vm.prank(operator);
    vm.expectRevert(MarketFactory.V3ShareMarket.selector);
    marketFactory.createMarket(p, new address[](0), new address[](0), false, false, false);
  }

  function testSetV3Oracle() public {
    _setUpV3();
    (MockV3Share share, MockV3Oracle v3Oracle) = _newV3Share(address(new ERC20Mock()));
    MockV3Oracle replacement = new MockV3Oracle(address(share), address(oracle));

    vm.prank(admin);
    vm.expectRevert(MarketFactory.InvalidV3Share.selector);
    marketFactory.setV3Oracle(address(share), address(replacement)); // not registered yet

    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(v3Oracle), _noExtra()));

    vm.expectRevert();
    marketFactory.setV3Oracle(address(share), address(replacement)); // not admin

    MockV3Oracle foreign = new MockV3Oracle(address(share), makeAddr("otherResilientOracle"));
    vm.prank(admin);
    vm.expectRevert(MarketFactory.InvalidV3Oracle.selector);
    marketFactory.setV3Oracle(address(share), address(foreign));

    vm.prank(admin);
    marketFactory.setV3Oracle(address(share), address(replacement));
    assertEq(marketFactory.v3OracleOf(address(share)), address(replacement));
    _createV3(_v3Market(address(new ERC20Mock()), address(share), address(replacement), _noExtra()));
  }

  function testSetV3Liquidator() public {
    address valid = address(new MockV3LiquidatorView(address(moolah), address(0)));
    vm.expectRevert();
    marketFactory.setV3Liquidator(valid); // not admin

    address wrongMoolah = address(new MockV3LiquidatorView(makeAddr("otherMoolah"), address(0)));
    vm.startPrank(admin);
    vm.expectRevert("ZeroAddress");
    marketFactory.setV3Liquidator(address(0));
    vm.expectRevert(MarketFactory.InvalidV3Liquidator.selector);
    marketFactory.setV3Liquidator(wrongMoolah);
    marketFactory.setV3Liquidator(valid);
    vm.stopPrank();
    assertEq(address(marketFactory.v3Liquidator()), valid);
  }
}

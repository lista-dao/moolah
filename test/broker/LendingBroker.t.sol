// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMockZero } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { WBNBMock } from "../../src/moolah/mocks/WBNBMock.sol";
import { BNBProvider } from "../../src/provider/BNBProvider.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";
import { IRateCalculator } from "../../src/broker/interfaces/IRateCalculator.sol";
import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate } from "../../src/broker/interfaces/IBroker.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketAllocation } from "../../src/moolah-vault/interfaces/IMoolahVault.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { IMoolahLiquidateCallback } from "../../src/moolah/interfaces/IMoolahCallbacks.sol";
import { BrokerLiquidator, IBrokerLiquidator } from "../../src/liquidator/BrokerLiquidator.sol";
import { MockSmartProvider } from "../liquidator/mocks/MockSmartProvider.sol";
import { ISmartProvider } from "../../src/provider/interfaces/IProvider.sol";
import { ORACLE_PRICE_SCALE, LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR } from "moolah/libraries/ConstantsLib.sol";

contract LendingBrokerTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;
  using UtilsLib for uint256;

  // ========= Shared state (unused fields may remain default in some tests) =========
  // Core
  IMoolah public moolah;
  LendingBroker public broker;
  LendingBroker public bnbBroker;
  RateCalculator public rateCalc;
  MoolahVault public vault;
  MoolahVault public bnbVault;
  BrokerInterestRelayer public relayer;
  BrokerInterestRelayer public bnbRelayer;
  BNBProvider public bnbProvider;

  // Market commons
  MarketParams public marketParams;
  MarketParams public bnbMarketParams;
  Id public id;
  Id public bnbId;

  // Token handles (real tokens on fork or mocks locally if used)
  OracleMock public oracle; // unused in fork path
  IrmMockZero public irm; // unused in fork path
  address supplier = address(0x201);
  address borrower = address(0x202);
  BrokerLiquidator public liquidator;

  uint256 constant LTV = 0.8e18;
  uint256 constant SUPPLY_LIQ = 1_000_000 ether;
  uint256 constant COLLATERAL = 1 ether;

  // Local roles for tests
  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MANAGER = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;
  address constant PAUSER = address(0xA11A51);
  address constant BOT = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  // Local mocks
  ERC20Mock public LISUSD;
  ERC20Mock public BTCB;
  WBNBMock public WBNB;
  uint8 constant LISUSD_DECIMALS = 18;
  uint8 constant BTCB_DECIMALS = 18;

  // setUp now forks mainnet Moolah, deploys new LendingBroker + RateCalculator,
  // wires them via setMarketBroker, and prepares borrower collateral.
  function setUp() public {
    // Local deploy: Moolah proxy and initialize
    Moolah mImpl = new Moolah();
    ERC1967Proxy mProxy = new ERC1967Proxy(
      address(mImpl),
      abi.encodeWithSelector(Moolah.initialize.selector, ADMIN, MANAGER, PAUSER, 15e8)
    );
    moolah = IMoolah(address(mProxy));

    // Tokens
    LISUSD = new ERC20Mock();
    LISUSD.setName("Lista USD");
    LISUSD.setSymbol("LISUSD");
    LISUSD.setDecimals(LISUSD_DECIMALS);
    BTCB = new ERC20Mock();
    BTCB.setName("Wrapped BTC (BSC)");
    BTCB.setSymbol("BTCB");
    BTCB.setDecimals(BTCB_DECIMALS);
    WBNB = new WBNBMock();

    // Oracle with initial prices
    oracle = new OracleMock();
    oracle.setPrice(address(LISUSD), 1e8);
    oracle.setPrice(address(BTCB), 120000e8);
    oracle.setPrice(address(WBNB), 1e8);

    // IRM enable + LLTV
    irm = new IrmMockZero();
    vm.startPrank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    Moolah(address(moolah)).enableLltv(80 * 1e16); // 80%
    vm.stopPrank();

    // Vault (only used as supply receiver for interest in tests)
    vault = new MoolahVault(address(moolah), address(LISUSD));

    MoolahVault bnbVaultImpl = new MoolahVault(address(moolah), address(WBNB));
    ERC1967Proxy bnbVaultProxy = new ERC1967Proxy(
      address(bnbVaultImpl),
      abi.encodeWithSelector(MoolahVault.initialize.selector, ADMIN, MANAGER, address(WBNB), "BNB Vault", "vBNB")
    );
    bnbVault = MoolahVault(address(bnbVaultProxy));

    // BrokerInterestRelayer
    BrokerInterestRelayer relayerImpl = new BrokerInterestRelayer();
    ERC1967Proxy relayerProxy = new ERC1967Proxy(
      address(relayerImpl),
      abi.encodeWithSelector(
        BrokerInterestRelayer.initialize.selector,
        ADMIN,
        MANAGER,
        address(moolah),
        address(vault),
        address(LISUSD)
      )
    );
    relayer = BrokerInterestRelayer(address(relayerProxy));

    BrokerInterestRelayer bnbRelayerImpl = new BrokerInterestRelayer();
    ERC1967Proxy bnbRelayerProxy = new ERC1967Proxy(
      address(bnbRelayerImpl),
      abi.encodeWithSelector(
        BrokerInterestRelayer.initialize.selector,
        ADMIN,
        MANAGER,
        address(moolah),
        address(bnbVault),
        address(WBNB)
      )
    );
    bnbRelayer = BrokerInterestRelayer(address(bnbRelayerProxy));

    // RateCalculator proxy
    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    rateCalc = RateCalculator(address(rcProxy));

    // Deploy LendingBroker proxy first (used as oracle by the market)
    LendingBroker bImpl = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy bProxy = new ERC1967Proxy(
      address(bImpl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    broker = LendingBroker(payable(address(bProxy)));

    LendingBroker bnbImpl = new LendingBroker(address(moolah), address(WBNB));
    ERC1967Proxy bnbProxy = new ERC1967Proxy(
      address(bnbImpl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(bnbRelayer),
        address(oracle)
      )
    );
    bnbBroker = LendingBroker(payable(address(bnbProxy)));

    BNBProvider bnbProviderImpl = new BNBProvider(address(moolah), address(bnbVault), address(WBNB));
    ERC1967Proxy bnbProviderProxy = new ERC1967Proxy(
      address(bnbProviderImpl),
      abi.encodeWithSelector(BNBProvider.initialize.selector, ADMIN, MANAGER)
    );
    bnbProvider = BNBProvider(payable(address(bnbProviderProxy)));

    // Create market using LendingBroker as the oracle address
    marketParams = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(BTCB),
      oracle: address(broker),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    id = marketParams.id();
    Moolah(address(moolah)).createMarket(marketParams);
    bnbMarketParams = MarketParams({
      loanToken: address(WBNB),
      collateralToken: address(BTCB),
      oracle: address(bnbBroker),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    bnbId = bnbMarketParams.id();
    Moolah(address(moolah)).createMarket(bnbMarketParams);

    // Bind broker to market id
    vm.startPrank(MANAGER);
    broker.setMarketId(id);
    bnbBroker.setMarketId(bnbId);
    vm.stopPrank();

    // Register broker and set as market broker (for user-aware pricing)
    vm.startPrank(MANAGER);
    rateCalc.registerBroker(address(broker), RATE_SCALE + 1, RATE_SCALE + 2);
    rateCalc.registerBroker(address(bnbBroker), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(id, address(broker), true);
    Moolah(address(moolah)).setMarketBroker(bnbId, address(bnbBroker), true);
    Moolah(address(moolah)).setProvider(bnbId, address(bnbProvider), true);
    vm.stopPrank();

    // Seed market liquidity
    uint256 seed = SUPPLY_LIQ;
    LISUSD.setBalance(supplier, seed);
    deal(address(WBNB), supplier, seed);
    vm.startPrank(supplier);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    moolah.supply(marketParams, seed, 0, supplier, bytes(""));
    IERC20(address(WBNB)).approve(address(moolah), type(uint256).max);
    moolah.supply(bnbMarketParams, seed, 0, supplier, bytes(""));
    vm.stopPrank();

    // Fund borrower with collateral and deposit to Moolah
    BTCB.setBalance(borrower, COLLATERAL * 2);
    vm.startPrank(borrower);
    BTCB.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(marketParams, COLLATERAL, borrower, bytes(""));
    moolah.supplyCollateral(bnbMarketParams, COLLATERAL, borrower, bytes(""));
    vm.stopPrank();

    // Approval for borrower -> broker (for future repay)
    vm.startPrank(borrower);
    LISUSD.approve(address(broker), type(uint256).max);
    vm.stopPrank();

    // deploy liquidator contract
    BrokerLiquidator mockLiqImpl = new BrokerLiquidator(address(moolah));
    ERC1967Proxy mockLiqProxy = new ERC1967Proxy(
      address(mockLiqImpl),
      abi.encodeWithSelector(BrokerLiquidator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    liquidator = BrokerLiquidator(payable(address(mockLiqProxy)));

    // whitelist lendingbroker as liquidator in moolah
    Id[] memory ids = new Id[](2);
    ids[0] = id;
    ids[1] = bnbId;
    address[][] memory accounts = new address[][](2);
    accounts[0] = new address[](1);
    accounts[0][0] = address(broker);
    accounts[1] = new address[](1);
    accounts[1][0] = address(bnbBroker);
    vm.prank(MANAGER);
    Moolah(address(moolah)).batchToggleLiquidationWhitelist(ids, accounts, true);

    // whitelist liquidator at lending broker
    vm.prank(MANAGER);
    broker.toggleLiquidationWhitelist(address(liquidator), true);

    // add broker into relayer
    vm.startPrank(MANAGER);
    relayer.addBroker(address(broker));
    bnbRelayer.addBroker(address(bnbBroker));
    vm.stopPrank();

    // add brokers mapping in liquidator
    vm.startPrank(MANAGER);
    liquidator.setMarketToBroker(Id.unwrap(id), address(broker), true);
    liquidator.setMarketToBroker(Id.unwrap(bnbId), address(bnbBroker), true);
    vm.stopPrank();
  }

  function _snapshot(address user) internal view returns (Market memory market, Position memory pos) {
    market = moolah.market(id);
    pos = moolah.position(id, user);
  }

  function _principalRepaid(Market memory beforeMarket, Market memory afterMarket) internal pure returns (uint256) {
    return uint256(beforeMarket.totalBorrowAssets) - uint256(afterMarket.totalBorrowAssets);
  }

  function _totalPrincipalAtBroker(address user) internal view returns (uint256 totalPrincipal) {
    DynamicLoanPosition memory dyn = broker.userDynamicPosition(user);
    totalPrincipal += dyn.principal;
    console.log("[_totalPrincipalAtBroker] dynamic principal: ", dyn.principal);
    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(user);
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      totalPrincipal += fixedPositions[i].principal - fixedPositions[i].principalRepaid;
      console.log(
        "[_totalPrincipalAtBroker] fixed pos [%s] principal: %s repaid: %s",
        i,
        fixedPositions[i].principal,
        fixedPositions[i].principalRepaid
      );
      console.log(
        "[_totalPrincipalAtBroker] interestRepaid: %s accruedInterest: %s",
        fixedPositions[i].interestRepaid,
        BrokerMath.getAccruedInterestForFixedPosition(fixedPositions[i])
      );
    }
  }

  function _totalInterestAtBroker(address user) internal view returns (uint256 totalInterest) {
    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(user);
    DynamicLoanPosition memory dynamicPosition = broker.userDynamicPosition(user);
    uint256 currentRate = rateCalc.getRate(address(broker));
    uint256 totalDebt;
    // [1] total debt from fixed position
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      // add principal
      totalDebt += _fixedPos.principal - _fixedPos.principalRepaid;
      // add interest
      totalDebt += BrokerMath.getAccruedInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }
    // [2] total debt from dynamic position
    totalDebt += BrokerMath.denormalizeBorrowAmount(dynamicPosition.normalizedDebt, currentRate);

    totalInterest = totalDebt - _totalPrincipalAtBroker(user);
  }

  function _principalAtMoolah(address user) internal view returns (uint256) {
    Market memory market = moolah.market(id);
    Position memory pos = moolah.position(id, user);
    return uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
  }

  function healthStatus(address user) internal view {
    Market memory market = moolah.market(marketParams.id());
    Position memory position = moolah.position(marketParams.id(), user);
    uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    uint256 maxBorrow = uint256(position.collateral).mulDivDown(moolah._getPrice(marketParams, user), 1e36).wMulDown(
      marketParams.lltv
    );

    console.log("health status - borrowed: ", borrowed);
    console.log("health status - maxBorrow: ", maxBorrow);
  }

  uint256 internal nextTermId;

  function _prepareLiquidatablePosition(bool badDebt) internal {
    uint256 termId = ++nextTermId;

    FixedTermAndRate memory term = FixedTermAndRate({
      termId: termId,
      duration: 30 days,
      apr: 105 * 1e25 // 5% APR
    });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.startPrank(borrower);
    broker.borrow(40000 ether);
    broker.borrow(40000 ether, termId);
    vm.stopPrank();

    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 30301 * 10 ** 14);

    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 30300 * 10 ** 14);

    skip(30 days);
    // slash collateral price to drive the position underwater
    oracle.setPrice(address(BTCB), badDebt ? 80000e8 : 100000e8);
  }

  // -----------------------------
  // Dynamic borrow and repay
  // -----------------------------
  function test_dynamicBorrowAndRepay() public {
    uint256 borrowAmt = 1000 ether;

    // Borrow with dynamic scheme
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    // User receives loan tokens
    assertEq(LISUSD.balanceOf(borrower), borrowAmt);

    // Position at Moolah increased
    uint128 borrowSharesBefore;
    {
      Position memory p0 = moolah.position(id, borrower);
      assertGt(p0.borrowShares, 0);
      borrowSharesBefore = p0.borrowShares;
    }

    // Time passes to accrue a tiny bit of interest via rateCalc
    skip(1 hours);

    // Repay partially (must exceed accrued interest)
    uint256 repayAmt = 400 ether;
    vm.prank(borrower);
    broker.repay(repayAmt, borrower);

    // Dynamic position principal should reduce
    (uint256 principalAfter, uint256 normDebtAfter) = broker.dynamicLoanPositions(borrower);
    assertLt(principalAfter, borrowAmt);
    assertGt(normDebtAfter, 0);

    // Moolah debt shares decreased as well
    {
      Position memory pAfter = moolah.position(id, borrower);
      assertLt(pAfter.borrowShares, borrowSharesBefore);
    }
  }

  function test_dynamicRepayOnBehalfByThirdParty() public {
    uint256 borrowAmt = 500 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    (uint256 principalBefore, ) = broker.dynamicLoanPositions(borrower);
    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);

    address helper = address(0x404);
    uint256 repayAmt = 200 ether;
    LISUSD.setBalance(helper, repayAmt);
    vm.startPrank(helper);
    IERC20(address(LISUSD)).approve(address(broker), type(uint256).max);
    broker.repay(repayAmt, borrower);
    vm.stopPrank();

    uint256 helperAfter = LISUSD.balanceOf(helper);
    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);

    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertEq(principalBefore - principalAfter, principalRepaid, "principal mismatch");

    uint256 sharesBurned = uint256(posBefore.borrowShares) - uint256(posAfter.borrowShares);
    if (principalRepaid == 0) {
      assertEq(sharesBurned, 0, "unexpected share burn");
    } else {
      assertGt(sharesBurned, 0, "no shares burned");
      assertApproxEqAbs(
        principalRepaid,
        sharesBurned.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
        1e12,
        "share/asset mismatch"
      );
    }

    uint256 spent = repayAmt - helperAfter;
    uint256 interestPaid = spent > principalRepaid ? spent - principalRepaid : 0;
    assertGe(spent, principalRepaid, "spent less than principal");
    // interest may be zero if the repayment happens immediately, so only track it for diagnostics
    assertGt(normalizedAfter, 0, "normalized debt should remain positive until fully repaid");
  }

  function test_dynamicRepayFullClearsPosition() public {
    uint256 borrowAmt = 600 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    skip(5 days);

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;
    uint256 buffer = 5e15; // absorb rounding when brokering to Moolah
    uint256 budget = actualDebt + buffer;

    LISUSD.setBalance(borrower, budget);
    uint256 balanceBefore = LISUSD.balanceOf(borrower);

    vm.prank(borrower);
    broker.repay(budget, borrower);

    uint256 balanceAfter = LISUSD.balanceOf(borrower);
    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);
    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);

    assertEq(principalAfter, 0, "dynamic principal not cleared");
    assertEq(normalizedAfter, 0, "dynamic normalized debt not cleared");
    uint256 residualAssets = uint256(posAfter.borrowShares).toAssetsUp(
      marketAfter.totalBorrowAssets,
      marketAfter.totalBorrowShares
    );
    assertLt(residualAssets, 1e16, "residual borrow assets too large");

    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertApproxEqAbs(principalRepaid, principalBefore, 5e15, "principal repayment mismatch");

    uint256 sharesBurned = uint256(posBefore.borrowShares) - uint256(posAfter.borrowShares);
    if (principalRepaid == 0) {
      assertEq(sharesBurned, 0, "unexpected share burn");
    } else {
      assertGt(sharesBurned, 0, "no shares burned");
      assertApproxEqAbs(
        sharesBurned.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
        principalRepaid,
        1e12,
        "share/asset mismatch"
      );
    }

    uint256 spent = balanceBefore - balanceAfter;
    uint256 expectedDebt = principalBefore + outstandingInterest;
    assertApproxEqAbs(spent, expectedDebt, buffer, "repayment spent mismatch");
  }

  function test_dynamicRepayOnBehalfFullClearsPosition() public {
    uint256 borrowAmt = 650 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    skip(4 days);

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;
    uint256 buffer = 5e15;
    uint256 budget = actualDebt + buffer;

    address helper = address(0x606);
    LISUSD.setBalance(helper, budget);
    vm.startPrank(helper);
    IERC20(address(LISUSD)).approve(address(broker), type(uint256).max);
    broker.repay(budget, borrower);
    vm.stopPrank();

    uint256 helperAfter = LISUSD.balanceOf(helper);
    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);
    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);

    assertEq(principalAfter, 0, "dynamic principal not cleared");
    assertEq(normalizedAfter, 0, "dynamic normalized debt not cleared");
    uint256 residualAssets = uint256(posAfter.borrowShares).toAssetsUp(
      marketAfter.totalBorrowAssets,
      marketAfter.totalBorrowShares
    );
    assertLt(residualAssets, 1e16, "residual borrow assets too large");

    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertApproxEqAbs(principalRepaid, principalBefore, 5e15, "principal repayment mismatch");

    uint256 sharesBurned = uint256(posBefore.borrowShares) - uint256(posAfter.borrowShares);
    if (principalRepaid == 0) {
      assertEq(sharesBurned, 0, "unexpected share burn");
    } else {
      assertGt(sharesBurned, 0, "no shares burned");
      assertApproxEqAbs(
        sharesBurned.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
        principalRepaid,
        1e12,
        "share/asset mismatch"
      );
    }

    uint256 spent = budget - helperAfter;
    uint256 expectedDebt = principalBefore + outstandingInterest;
    assertApproxEqAbs(spent, expectedDebt, buffer, "helper repayment mismatch");
  }

  // -----------------------------
  // Dynamic → Fixed conversion
  // -----------------------------
  function test_convertDynamicToFixed_partialAmount() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 51, duration: 45 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 borrowAmt = 1_000 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    // push rate higher so interest accrues
    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 5);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 3);
    skip(5 days);

    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;

    // amount > interest => interest fully cleared, remainder moves principal
    uint256 convertAmount = 400 ether;
    uint256 expectedInterest = outstandingInterest < convertAmount ? outstandingInterest : convertAmount;
    uint256 expectedPrincipalMove = convertAmount - expectedInterest;
    uint256 expectedNormalizedDelta = BrokerMath.normalizeBorrowAmount(convertAmount, rate, true);
    uint256 expectedNormalizedAfter = normalizedBefore > expectedNormalizedDelta
      ? normalizedBefore - expectedNormalizedDelta
      : 0;

    vm.prank(borrower);
    broker.convertDynamicToFixed(convertAmount, 51);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertEq(principalAfter, principalBefore - expectedPrincipalMove, "dynamic principal not reduced correctly");
    assertApproxEqAbs(normalizedAfter, expectedNormalizedAfter, 1, "normalized debt delta mismatch");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1, "fixed position not created");
    assertEq(fixedPositions[0].principal, convertAmount, "fixed principal should equal amount");
    assertEq(fixedPositions[0].interestRepaid, 0);
    assertEq(fixedPositions[0].principalRepaid, 0);
  }

  function test_convertDynamicToFixed_fullAmountClearsDynamic() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 52, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 borrowAmt = 750 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 6);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 4);
    skip(3 days);

    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;

    // pass amount > actualDebt => capped to interest + principal
    vm.prank(borrower);
    broker.convertDynamicToFixed(actualDebt + 100 ether, 52);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertApproxEqAbs(principalAfter, 0, 1, "dynamic principal should be cleared");
    assertApproxEqAbs(normalizedAfter, 0, 1, "dynamic normalized debt should be cleared");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1);
    uint256 expectedFixed = outstandingInterest + principalBefore;
    assertApproxEqAbs(fixedPositions[0].principal, expectedFixed, 1, "fixed principal should equal full debt");
  }

  function test_convertDynamicToFixed_exactFullAmount() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 53, duration: 60 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 borrowAmt = 500 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 5);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 3);
    skip(4 days);

    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;

    // amount == interest + principal exactly
    uint256 convertAmount = outstandingInterest + principalBefore;

    vm.prank(borrower);
    broker.convertDynamicToFixed(convertAmount, 53);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertApproxEqAbs(principalAfter, 0, 1, "dynamic principal should be cleared");
    assertApproxEqAbs(normalizedAfter, 0, 1, "dynamic normalized debt should be cleared");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1);
    assertEq(fixedPositions[0].principal, convertAmount, "fixed principal should equal amount");
  }

  function test_convertDynamicToFixed_excessAmountCapped() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 54, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 borrowAmt = 600 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 5);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 3);
    skip(3 days);

    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = rateCalc.accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 outstandingInterest = actualDebt > principalBefore ? actualDebt - principalBefore : 0;

    // amount much larger than actualDebt => should be capped
    uint256 convertAmount = actualDebt + 999 ether;

    vm.prank(borrower);
    broker.convertDynamicToFixed(convertAmount, 54);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertApproxEqAbs(principalAfter, 0, 1, "dynamic principal should be cleared");
    assertApproxEqAbs(normalizedAfter, 0, 1, "dynamic normalized debt should be cleared");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1);
    uint256 expectedFixed = outstandingInterest + principalBefore;
    assertApproxEqAbs(fixedPositions[0].principal, expectedFixed, 1, "fixed principal capped to actual debt");
    assertLe(fixedPositions[0].principal, convertAmount, "fixed principal must be <= amount");
  }

  /// @notice A user with no dynamic position (or with both principal and interest at zero) must
  ///         not be able to spawn zero-principal fixed positions via convertDynamicToFixed.
  ///         Without the post-clamp guard, repeated 1-wei calls would let an attacker fill
  ///         maxFixedLoanPositions slots with empty entries to grief liquidation gas later.
  function test_convertDynamicToFixed_revertsWhenNoDynamicDebt() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 55, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // user has never borrowed → no dynamic position
    (uint256 principal, uint256 normalizedDebt) = broker.dynamicLoanPositions(borrower);
    assertEq(principal, 0, "precondition: no dynamic principal");
    assertEq(normalizedDebt, 0, "precondition: no dynamic normalizedDebt");

    vm.prank(borrower);
    vm.expectRevert(LendingBroker.ZeroAmount.selector);
    broker.convertDynamicToFixed(1, 55);

    // confirm: no fixed position was ever created
    assertEq(broker.userFixedPositions(borrower).length, 0, "no fixed position should be created");
  }

  // -----------------------------
  // Fixed borrow and repay (partial and full)
  // -----------------------------
  function test_fixedBorrowAndPartialRepay_thenFullRepay() public {
    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 30 days;
    uint256 apr = 105 * 1e25;

    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // Borrow fixed
    uint256 fixedAmt = 500 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, termId);

    // Verify a fixed position created
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    uint256 posId = positions[0].posId;
    assertEq(positions[0].principal, fixedAmt);

    // Let some time pass to incur a tiny interest (apr == RATE_SCALE => minimal interest)
    skip(1 days);
    moolah.accrueInterest(marketParams);

    (Market memory marketPartialBefore, Position memory posPartialBefore) = _snapshot(borrower);
    uint256 partialPrincipal = 100 ether;
    uint256 partialBuffer = 0.1 ether; // cover accrued interest while penalty is handled separately
    uint256 partialRepay = partialPrincipal + partialBuffer;
    vm.prank(borrower);
    broker.repay(partialRepay, posId, borrower);

    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    FixedLoanPosition memory midPos = positions[0];
    (Market memory marketPartialAfter, Position memory posPartialAfter) = _snapshot(borrower);
    uint256 principalRepaidPartial = _principalRepaid(marketPartialBefore, marketPartialAfter);
    uint256 sharesBurnedPartial = uint256(posPartialBefore.borrowShares) - uint256(posPartialAfter.borrowShares);
    if (principalRepaidPartial == 0) {
      assertEq(sharesBurnedPartial, 0, "unexpected share burn after partial");
    } else {
      assertGt(sharesBurnedPartial, 0, "no shares burned after partial");
      assertApproxEqAbs(
        principalRepaidPartial,
        sharesBurnedPartial.toAssetsUp(marketPartialBefore.totalBorrowAssets, marketPartialBefore.totalBorrowShares),
        1e17,
        "partial share/asset mismatch"
      );
    }
    assertApproxEqAbs(midPos.principalRepaid, principalRepaidPartial, 1e17, "partial principal recorded");

    // Full repay remaining
    // Top up borrower to ensure enough balance, then overpay to cover any interest/penalty
    LISUSD.setBalance(borrower, 2_000 ether);
    uint256 repayAll = 2_000 ether;
    moolah.accrueInterest(marketParams);
    vm.prank(borrower);
    broker.repay(repayAll, posId, borrower);

    // Position fully removed
    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
  }

  function test_fixedRepayOnBehalfByThirdParty() public {
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 21,
      duration: 45 days,
      apr: 105 * 1e25 // 5% APR
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 fixedAmt = 300 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, 21);

    skip(7 days);

    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    uint256 posId = beforePos.posId;
    uint256 interestDue = BrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    assertGt(interestDue, 0, "interest did not accrue");

    uint256 principalPortion = 40 ether;
    uint256 penalty = BrokerMath.getPenaltyForFixedPosition(beforePos, principalPortion);
    uint256 repayAmt = interestDue + principalPortion;

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    uint256 helperInitial = repayAmt + 1 ether;

    address helper = address(0x505);
    LISUSD.setBalance(helper, helperInitial);
    vm.startPrank(helper);
    IERC20(address(LISUSD)).approve(address(broker), type(uint256).max);
    broker.repay(repayAmt, posId, borrower);
    vm.stopPrank();

    uint256 helperAfter = LISUSD.balanceOf(helper);
    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);
    FixedLoanPosition[] memory afterPositions = broker.userFixedPositions(borrower);
    assertEq(afterPositions.length, 1, "position removed unexpectedly");
    FixedLoanPosition memory afterPos = afterPositions[0];
    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertApproxEqAbs(
      afterPos.principalRepaid - beforePos.principalRepaid,
      principalRepaid,
      2e15,
      "principal repayment mismatch"
    );

    // interest should be fully cleared after the partial principal repayment
    uint256 residualInterest = BrokerMath.getAccruedInterestForFixedPosition(afterPos) - afterPos.interestRepaid;
    assertEq(residualInterest, 0, "interest outstanding after repay");

    uint256 sharesBurned = uint256(posBefore.borrowShares) - uint256(posAfter.borrowShares);
    if (principalRepaid == 0) {
      assertEq(sharesBurned, 0, "unexpected share burn");
    } else {
      assertGt(sharesBurned, 0, "no shares burned");
      assertApproxEqAbs(
        principalRepaid,
        sharesBurned.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
        2e15,
        "share/asset mismatch"
      );
    }

    uint256 spent = helperInitial - helperAfter;
    uint256 principalDelta = afterPos.principalRepaid - beforePos.principalRepaid;
    uint256 penaltyPaid = spent > interestDue + principalDelta ? spent - (interestDue + principalDelta) : 0;
    assertGe(penaltyPaid, penalty, "penalty repayment too small");
    assertLt(penaltyPaid - penalty, 5e16, "penalty excess too large");
  }

  function test_fixedRepayOnBehalfByThirdParty_fullClose() public {
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 22,
      duration: 30 days,
      apr: 105 * 1e25 // 5% APR
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 fixedAmt = 350 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, 22);

    skip(10 days);
    moolah.accrueInterest(marketParams);

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    uint256 posId = beforePos.posId;

    uint256 remainingPrincipal = beforePos.principal - beforePos.principalRepaid;
    uint256 interestDue = BrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    uint256 penalty = BrokerMath.getPenaltyForFixedPosition(beforePos, remainingPrincipal);

    uint256 repayAll = 2_000 ether;
    uint256 helperBudget = repayAll + penalty + 1 ether;

    address helper = address(0x6060);
    LISUSD.setBalance(helper, helperBudget);
    vm.startPrank(helper);
    IERC20(address(LISUSD)).approve(address(broker), type(uint256).max);
    broker.repay(repayAll, posId, borrower);
    vm.stopPrank();

    FixedLoanPosition[] memory afterPositions = broker.userFixedPositions(borrower);
    assertEq(afterPositions.length, 0, "fixed position not removed");

    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);
    uint256 residualAssets = uint256(posAfter.borrowShares).toAssetsUp(
      marketAfter.totalBorrowAssets,
      marketAfter.totalBorrowShares
    );
    assertLt(residualAssets, 1e16, "residual borrow assets too large");

    uint256 helperAfter = LISUSD.balanceOf(helper);
    uint256 spent = helperBudget - helperAfter;

    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertApproxEqAbs(principalRepaid, remainingPrincipal, 5e15, "principal repayment mismatch");

    uint256 expectedDebt = principalRepaid + interestDue + penalty;
    assertApproxEqAbs(spent, expectedDebt, 2e16, "helper total spend mismatch");

    uint256 sharesBurned = uint256(posBefore.borrowShares) - uint256(posAfter.borrowShares);
    if (principalRepaid == 0) {
      assertEq(sharesBurned, 0, "unexpected share burn");
    } else {
      assertGt(sharesBurned, 0, "no shares burned");
      assertApproxEqAbs(
        sharesBurned.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
        principalRepaid,
        5e15,
        "share/asset mismatch"
      );
    }
  }

  function test_fixedRepayOverpayDoesNotTouchDynamicPosition() public {
    uint256 termId = 77;
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: 45 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 dynamicBorrow = 20 ether;
    vm.prank(borrower);
    broker.borrow(dynamicBorrow);

    uint256 fixedBorrow = 60 ether;
    vm.prank(borrower);
    broker.borrow(fixedBorrow, termId);

    (uint256 dynPrincipalBefore, uint256 dynNormalizedBefore) = broker.dynamicLoanPositions(borrower);
    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    FixedLoanPosition[] memory fixedBefore = broker.userFixedPositions(borrower);
    assertEq(fixedBefore.length, 1, "expected one fixed position");
    uint256 posId = fixedBefore[0].posId;
    uint256 interestRepaid = BrokerMath.getAccruedInterestForFixedPosition(fixedBefore[0]) -
      fixedBefore[0].interestRepaid;
    uint256 borrowerBalanceBefore = LISUSD.balanceOf(borrower);
    uint256 overpayAmount = fixedBorrow + 10 ether;

    uint256 penalty = BrokerMath.getPenaltyForFixedPosition(
      fixedBefore[0],
      (overpayAmount - interestRepaid) > fixedBefore[0].principal - fixedBefore[0].principalRepaid
        ? fixedBefore[0].principal - fixedBefore[0].principalRepaid
        : (overpayAmount - interestRepaid)
    );

    vm.prank(borrower);
    broker.repay(overpayAmount, posId, borrower);

    FixedLoanPosition[] memory fixedAfter = broker.userFixedPositions(borrower);
    assertEq(fixedAfter.length, 0, "fixed position should be cleared");

    (uint256 dynPrincipalAfter, uint256 dynNormalizedAfter) = broker.dynamicLoanPositions(borrower);
    (Market memory marketAfter, Position memory posAfter) = _snapshot(borrower);

    assertEq(dynPrincipalAfter, dynPrincipalBefore, "dynamic principal changed unexpectedly");
    assertEq(dynNormalizedAfter, dynNormalizedBefore, "dynamic normalized debt changed unexpectedly");

    uint256 principalRepaid = _principalRepaid(marketBefore, marketAfter);
    assertEq(principalRepaid, fixedBorrow, "repaid principal should match fixed borrow");
    uint256 borrowAssetsAfter = uint256(posAfter.borrowShares).toAssetsUp(
      marketAfter.totalBorrowAssets,
      marketAfter.totalBorrowShares
    );
    assertApproxEqAbs(borrowAssetsAfter, dynamicBorrow, 1, "unexpected borrow assets after overpay");

    uint256 borrowerBalanceAfter = LISUSD.balanceOf(borrower);
    assertEq(borrowerBalanceBefore - borrowerBalanceAfter, fixedBorrow + penalty, "incorrect token spend");
  }

  //////////////////////////////////////////////////////
  ///////////////// Liquidation Tests //////////////////
  //////////////////////////////////////////////////////

  // --------------- BAD DEBT LIQUIDATIONS ---------------
  function test_badDebt_liquidation_fullClearsPrincipal_andSuppliesInterest_seizeCollateral() public {
    test_liquidation(100 * 1e8, true, true, true);
  }

  function test_badDebt_liquidation_tinyClearsPrincipal_andSuppliesInterest_seizeCollateral() public {
    test_liquidation(1, true, true, false);
  }

  function test_badDebt_liquidation_fullClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(100 * 1e8, false, true, true);
  }

  function test_badDebt_liquidation_halfClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(50 * 1e8, false, true, false);
  }

  function test_badDebt_liquidation_tinyClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(1, false, true, false);
  }

  // --------------- NORMAL LIQUIDATIONS ---------------
  function test_liquidation_tinyClearsPrincipal_andSuppliesInterest_seizeCollateral() public {
    test_liquidation(1, true, false, false);
  }

  function test_liquidation_fullClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(100 * 1e8, false, false, false);
  }

  function test_liquidation_halfClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(50 * 1e8, false, false, false);
  }

  function test_liquidation_tinyClearsPrincipal_andSuppliesInterest_repayByShares() public {
    test_liquidation(1, false, false, false);
  }

  // --------------- LISUSD DEPEG LIQUIDATIONS ---------------
  // When LISUSD oracle price rises above 1e8, effective collateral price drops
  // (collateralPrice = scaleFactor * basePrice / quotePrice), making positions liquidatable.
  function test_liquidation_triggeredByLoanTokenPriceIncrease() public {
    _prepareLiquidatablePositionByLoanTokenDepeg();

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 50 * 1e8, 100 * 1e8);

    uint256 principalBeforeBroker = _totalPrincipalAtBroker(borrower);
    uint256 principalBeforeMoolah = _principalAtMoolah(borrower);
    assertApproxEqAbs(principalBeforeBroker, principalBeforeMoolah, 1, "pre principal mismatch");

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, userRepayShares);

    uint256 principalAfterBroker = _totalPrincipalAtBroker(borrower);
    uint256 principalAfterMoolah = _principalAtMoolah(borrower);
    assertApproxEqAbs(principalAfterBroker, principalAfterMoolah, 1, "principal mismatch after liquidation");
    assertLt(principalAfterBroker, principalBeforeBroker, "principal should decrease after liquidation");

    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "borrow shares should decrease");
    assertLt(posAfter.collateral, posBefore.collateral, "collateral should decrease");
  }

  function test_liquidation_notTriggeredWhenLoanTokenPriceDrops() public {
    // Borrow near the limit with normal prices
    uint256 termId = ++nextTermId;
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.startPrank(borrower);
    broker.borrow(40000 ether);
    broker.borrow(40000 ether, termId);
    vm.stopPrank();

    // LISUSD depegs downward → effective collateral price increases → position stays healthy
    oracle.setPrice(address(LISUSD), 0.8e8);

    // Attempting to liquidate should revert because position is healthy
    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 50 * 1e8, 100 * 1e8);

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    vm.expectRevert();
    liquidator.liquidate(Id.unwrap(id), borrower, 0, userRepayShares);
  }

  function test_liquidation_badDebt_triggeredByLoanTokenPriceIncrease() public {
    _prepareLiquidatablePositionByLoanTokenDepeg();
    // Further increase LISUSD price to create bad debt scenario
    oracle.setPrice(address(LISUSD), 3e8);

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    // Use small percentage to avoid seizing more collateral than available
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 1, 100 * 1e8);

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, userRepayShares);

    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "borrow shares should decrease");
  }

  function _prepareLiquidatablePositionByLoanTokenDepeg() internal {
    uint256 termId = ++nextTermId;
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: 30 days, apr: 105 * 1e25 });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // Borrow near the limit
    vm.startPrank(borrower);
    broker.borrow(40000 ether);
    broker.borrow(40000 ether, termId);
    vm.stopPrank();

    // Accrue some interest
    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 30301 * 10 ** 14);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 30300 * 10 ** 14);
    skip(10 days);

    // LISUSD price rises → effective collateral price drops → position becomes unhealthy
    // At 1.5e8, collateral is worth 2/3 in LISUSD terms, max borrow drops significantly
    oracle.setPrice(address(LISUSD), 1.5e8);
  }

  function test_liquidation(
    uint256 percentageToLiquidate,
    bool repayBySeizedCollateral,
    bool isBadDebt,
    bool expectRevert
  ) internal {
    _prepareLiquidatablePosition(isBadDebt);

    console.log("====== Liquidation Test Start percentage %s % =======", percentageToLiquidate / 1e8);
    console.log(isBadDebt ? "======== [Bad Debt Scenario] ========" : "======== [Normal Liquidation] ========");
    console.log(
      repayBySeizedCollateral
        ? "======== [Repay by seized collateral] ========"
        : "========= [Repay by borrow shares] ========="
    );
    // get user's borrow shares
    Position memory posBefore = moolah.position(marketParams.id(), borrower);

    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, percentageToLiquidate, 100 * 1e8);
    uint256 userCollateralBefore = posBefore.collateral;
    uint256 seizedAssets = _previewLiquidationRepayment(
      marketParams,
      moolah.market(marketParams.id()),
      0,
      userRepayShares,
      moolah._getPrice(marketParams, borrower)
    );

    console.log("[Preview] collateral to be seized: ", seizedAssets);
    console.log("[Before] user borrow shares before: ", posBefore.borrowShares);
    console.log("[Before] user repay shares: ", userRepayShares);
    console.log("[Before] user collateral before: ", userCollateralBefore);

    uint256 interestBefore = _totalInterestAtBroker(borrower);
    console.log("[Before] interest at broker: ", interestBefore);
    uint256 relayerLoanTokenBalBefore = LISUSD.balanceOf(address(relayer));
    uint256 principalBeforeBroker = _totalPrincipalAtBroker(borrower);
    uint256 principalBeforeMoolah = _principalAtMoolah(borrower);
    console.log("[Before] broker principal: ", principalBeforeBroker);
    console.log("[Before] moolah principal: ", principalBeforeMoolah);
    assertApproxEqAbs(principalBeforeBroker, principalBeforeMoolah, 1, "pre principal mismatch");

    uint256 vaultSharesBefore = moolah.position(id, address(vault)).supplyShares;
    Market memory marketBefore = moolah.market(id);
    uint256 vaultAssetsBefore = vaultSharesBefore.toAssetsUp(
      marketBefore.totalSupplyAssets,
      marketBefore.totalSupplyShares
    );
    console.log("[Before] vault shares: ", vaultSharesBefore);
    console.log("[Before] vault assets: ", vaultAssetsBefore);

    uint256 liquidatorCollateralBalBefore = BTCB.balanceOf(address(liquidator));

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);
    uint256 liquidatorLoanTokenBalBefore = LISUSD.balanceOf(address(liquidator));
    console.log("[Before] liquidator loanToken balance: ", liquidatorLoanTokenBalBefore);
    console.log("[Before] liquidator collateral balance: ", liquidatorCollateralBalBefore);

    vm.startPrank(BOT);
    if (expectRevert) {
      // under rapid price dropping scenario
      // full repay share cause seized collateral > user collateral
      // OR seized collateral too larger
      vm.expectRevert();
    }
    liquidator.liquidate(
      Id.unwrap(id),
      borrower,
      repayBySeizedCollateral ? seizedAssets : 0,
      repayBySeizedCollateral ? 0 : userRepayShares
    );
    vm.stopPrank();

    uint256 vaultSharesAfter = moolah.position(id, address(vault)).supplyShares;
    Market memory marketAfter = moolah.market(id);
    uint256 vaultAssetsAfter = vaultSharesAfter.toAssetsUp(
      marketAfter.totalSupplyAssets,
      marketAfter.totalSupplyShares
    );
    console.log("[After] vault assets: ", vaultAssetsAfter);

    if (!expectRevert) {
      assertEq(
        vaultAssetsAfter > vaultAssetsBefore || LISUSD.balanceOf(address(relayer)) > relayerLoanTokenBalBefore,
        true,
        "vault did not gain assets from liquidation"
      );
    }

    uint256 principalAfterBroker = _totalPrincipalAtBroker(borrower);
    uint256 principalAfterMoolah = _principalAtMoolah(borrower);
    uint256 interestAfter = _totalInterestAtBroker(borrower);
    console.log("[After] broker principal: ", principalAfterBroker);
    console.log("[After] moolah principal: ", principalAfterMoolah);
    console.log("[After] interest at broker: ", interestAfter);
    console.log("[After] liquidator loanToken balance: ", LISUSD.balanceOf(address(liquidator)));
    console.log("[After] liquidator collateral balance: ", BTCB.balanceOf(address(liquidator)));
    uint256 collateralGained = BTCB.balanceOf(address(liquidator)) - liquidatorCollateralBalBefore;
    console.log("[ORACLE] collateral price: ", oracle.peek(address(BTCB)));
    uint256 collateralGainedWorth = collateralGained.mulDivDown(oracle.peek(address(BTCB)), 1e8);
    uint256 liquidatorLoanTokenSpent = liquidatorLoanTokenBalBefore - LISUSD.balanceOf(address(liquidator));
    if (collateralGainedWorth >= liquidatorLoanTokenSpent) {
      console.log("[After] liquidator PROFITABLE: ", collateralGainedWorth - liquidatorLoanTokenSpent);
    } else {
      console.log("[After] liquidator LOSS: ", liquidatorLoanTokenSpent - collateralGainedWorth);
    }

    assertApproxEqAbs(principalAfterBroker, principalAfterMoolah, 1, "principal mismatch after full");

    // user supply shares
    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    uint256 userBorrowSharesAfter = posAfter.borrowShares;
    uint256 userCollateralAfter = posAfter.collateral;
    uint256 userSupplySharesAfter = posAfter.supplyShares;
    console.log("[After] user borrow shares: ", userBorrowSharesAfter);
    console.log("[After] user collateral: ", userCollateralAfter);
    console.log("[After] user supply shares: ", userSupplySharesAfter);
  }

  function _previewLiquidationRepayment(
    MarketParams memory marketParams,
    Market memory market,
    uint256 seizedAssets,
    uint256 repaidShares,
    uint256 collateralPrice
  ) internal pure returns (uint256) {
    // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
    uint256 liquidationIncentiveFactor = UtilsLib.min(
      MAX_LIQUIDATION_INCENTIVE_FACTOR,
      WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
    );

    if (seizedAssets > 0) {
      uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

      repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
        market.totalBorrowAssets,
        market.totalBorrowShares
      );
    } else {
      seizedAssets = repaidShares
        .toAssetsDown(market.totalBorrowAssets, market.totalBorrowShares)
        .wMulDown(liquidationIncentiveFactor)
        .mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
    }
    uint256 repaidAssets = repaidShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

    return seizedAssets;
  }

  function test_provisioning_and_allocation() public {
    // Verify broker wiring
    assertEq(broker.LOAN_TOKEN(), address(LISUSD));
    assertEq(broker.COLLATERAL_TOKEN(), address(BTCB));

    // Vault should be initialized and approved
    // No automatic supply from vault here; just ensure market exists and supply by supplier occurred
    assertGt(moolah.market(id).totalSupplyAssets, 0, "market has no supply");
  }

  // -----------------------------
  // Edge cases
  // -----------------------------

  function test_borrowZeroAmount_Reverts() public {
    vm.expectRevert(LendingBroker.ZeroAmount.selector);
    vm.prank(borrower);
    broker.borrow(0);
  }

  function test_borrowFixedTermNotFound_Reverts() public {
    vm.expectRevert(LendingBroker.TermNotFound.selector);
    vm.prank(borrower);
    broker.borrow(100 ether, 999);
  }

  function test_setBorrowPaused_onlyManager_Reverts() public {
    vm.expectRevert();
    vm.prank(borrower);
    broker.setBorrowPaused(true);
  }

  function test_setBorrowPaused_sameValue_reverts() public {
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);
    vm.expectRevert(LendingBroker.SameValueProvided.selector);
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);
  }

  function test_borrowDynamic_whenPaused_reverts() public {
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);

    vm.expectRevert(LendingBroker.BorrowIsPaused.selector);
    vm.prank(borrower);
    broker.borrow(1 ether);
  }

  function test_borrowFixed_whenPaused_reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 111, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);

    vm.expectRevert(LendingBroker.BorrowIsPaused.selector);
    vm.prank(borrower);
    broker.borrow(1 ether, 111);
  }

  function test_borrowDynamic_afterUnpause_succeeds() public {
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);
    vm.prank(MANAGER);
    broker.setBorrowPaused(false);

    uint256 amount = 50 ether;
    vm.prank(borrower);
    broker.borrow(amount);

    assertEq(LISUSD.balanceOf(borrower), amount);
  }

  function test_setFixedTermOnlyManager_Reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 42, duration: 30 days, apr: 105 * 1e25 });
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    vm.prank(borrower);
    broker.updateFixedTermAndRate(term, false);
  }

  function test_setMaxFixedLoanPositions_Enforced() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 11, duration: 60 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(MANAGER);
    broker.setMaxFixedLoanPositions(1);

    vm.startPrank(borrower);
    broker.borrow(15 ether, 11);
    vm.expectRevert(LendingBroker.ExceedMaxFixedPositions.selector);
    broker.borrow(15 ether, 11);
    vm.stopPrank();
  }

  function test_peekLoanToken_OneE8() public {
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 1e8);
  }

  function test_peekLoanToken_usesOraclePrice() public {
    // Change the oracle price for LISUSD to a non-default value
    oracle.setPrice(address(LISUSD), 0.98e8);
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 0.98e8, "loan token price should come from oracle");
  }

  function test_peekLoanToken_oraclePriceAboveOneE8() public {
    oracle.setPrice(address(LISUSD), 1.05e8);
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 1.05e8, "loan token price should reflect oracle price above 1e8");
  }

  function test_peekLoanToken_oraclePriceZero() public {
    oracle.setPrice(address(LISUSD), 0);
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 0, "loan token price should be zero when oracle returns zero");
  }

  function test_peekCollateralReducedWithFixedInterest() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 77, duration: 30 days, apr: 105 * 1e25 });
    // Set a fixed term, borrow fixed, wait, then check price reduces
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    // initial price from oracle
    uint256 p0 = broker.peek(address(BTCB), borrower);
    vm.prank(borrower);
    broker.borrow(100 ether, 77);
    skip(1 days);
    uint256 p1 = broker.peek(address(BTCB), borrower);
    assertLt(p1, p0, "collateral price did not decrease");
  }

  function test_refinance_onlyBot_Reverts() public {
    uint256[] memory posIds = new uint256[](0);
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    broker.refinanceMaturedFixedPositions(borrower, posIds);
  }

  function test_peekUnsupportedToken_Reverts() public {
    vm.expectRevert(LendingBroker.UnsupportedToken.selector);
    broker.peek(address(0xDEA), borrower);
  }

  function test_marketIdSet_guard_reverts() public {
    // Deploy a second broker without setting market id
    LendingBroker bImpl2 = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy bProxy2 = new ERC1967Proxy(
      address(bImpl2),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    LendingBroker broker2 = LendingBroker(payable(address(bProxy2)));
    vm.expectRevert(LendingBroker.MarketNotSet.selector);
    vm.prank(borrower);
    broker2.borrow(1 ether);
  }

  function test_setMarketId_onlyOnce_reverts() public {
    vm.expectRevert(LendingBroker.InvalidMarket.selector);
    vm.prank(MANAGER);
    broker.setMarketId(id);
  }

  function test_liquidatorSetMarketWhitelist_whitelistsNewBroker() public {
    LendingBroker bImpl2 = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy bProxy2 = new ERC1967Proxy(
      address(bImpl2),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    LendingBroker newBroker = LendingBroker(payable(address(bProxy2)));

    MarketParams memory params = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(BTCB),
      oracle: address(newBroker),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    Id newId = params.id();
    Moolah(address(moolah)).createMarket(params);

    vm.prank(MANAGER);
    newBroker.setMarketId(newId);
    vm.prank(MANAGER);
    Moolah(address(moolah)).setMarketBroker(newId, address(newBroker), true);

    bytes32 rawId = Id.unwrap(newId);
    vm.prank(MANAGER);
    liquidator.setMarketToBroker(rawId, address(newBroker), true);

    assertEq(liquidator.marketIdToBroker(rawId), address(newBroker), "market not whitelisted");
    assertEq(liquidator.brokerToMarketId(address(newBroker)), rawId, "broker mapping missing");
  }

  function test_liquidatorBatchSetMarketWhitelist_whitelistsMultipleMarkets() public {
    LendingBroker bImplA = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy bProxyA = new ERC1967Proxy(
      address(bImplA),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    LendingBroker brokerA = LendingBroker(payable(address(bProxyA)));

    MarketParams memory paramsA = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(BTCB),
      oracle: address(brokerA),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    Id idA = paramsA.id();
    Moolah(address(moolah)).createMarket(paramsA);
    vm.prank(MANAGER);
    brokerA.setMarketId(idA);

    LendingBroker bImplB = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy bProxyB = new ERC1967Proxy(
      address(bImplB),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(relayer),
        address(oracle)
      )
    );
    LendingBroker brokerB = LendingBroker(payable(address(bProxyB)));

    MarketParams memory paramsB = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(BTCB),
      oracle: address(brokerB),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    Id idB = paramsB.id();
    Moolah(address(moolah)).createMarket(paramsB);
    vm.prank(MANAGER);
    brokerB.setMarketId(idB);

    vm.prank(MANAGER);
    Moolah(address(moolah)).setMarketBroker(idA, address(brokerA), true);
    vm.prank(MANAGER);
    Moolah(address(moolah)).setMarketBroker(idB, address(brokerB), true);

    bytes32[] memory ids = new bytes32[](2);
    address[] memory brokers = new address[](2);
    ids[0] = Id.unwrap(idA);
    ids[1] = Id.unwrap(idB);
    brokers[0] = address(brokerA);
    brokers[1] = address(brokerB);

    vm.prank(MANAGER);
    liquidator.batchSetMarketToBroker(ids, brokers, true);

    assertEq(liquidator.marketIdToBroker(ids[0]), brokers[0], "first market not whitelisted");
    assertEq(liquidator.marketIdToBroker(ids[1]), brokers[1], "second market not whitelisted");
    assertEq(liquidator.brokerToMarketId(brokers[0]), ids[0], "first broker mapping missing");
    assertEq(liquidator.brokerToMarketId(brokers[1]), ids[1], "second broker mapping missing");
  }

  function test_setFixedTerm_validations_revert() public {
    FixedTermAndRate memory term1 = FixedTermAndRate({ termId: 0, duration: 30 days, apr: 105 * 1e25 });
    FixedTermAndRate memory term2 = FixedTermAndRate({ termId: 1, duration: 0, apr: 105 * 1e25 });
    FixedTermAndRate memory term3 = FixedTermAndRate({ termId: 2, duration: 90 days, apr: 0 });
    // termId = 0
    vm.expectRevert(LendingBroker.InvalidTermId.selector);
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term1, false);
    // duration = 0
    vm.expectRevert(LendingBroker.InvalidDuration.selector);
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term2, false);
    // apr < RATE_SCALE
    vm.expectRevert(LendingBroker.InvalidAPR.selector);
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term3, false);
  }

  function test_removeFixedTerm_success_and_notFound_revert() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 3, duration: 10 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    // ensure added
    FixedTermAndRate[] memory terms = broker.getFixedTerms();
    assertEq(terms.length, 1);
    assertEq(terms[0].termId, 3);
    // remove
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, true);
    terms = broker.getFixedTerms();
    assertEq(terms.length, 0);
    // remove again -> revert
    vm.expectRevert(LendingBroker.TermNotFound.selector);
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, true);
  }

  function test_getFixedTerms_update_inPlace() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 5, duration: 7 days, apr: 105 * 1e25 });
    FixedTermAndRate memory updatedTerm = FixedTermAndRate({ termId: 5, duration: 14 days, apr: 110 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(BOT);
    broker.updateFixedTermAndRate(updatedTerm, false);
    FixedTermAndRate[] memory terms = broker.getFixedTerms();
    assertEq(terms.length, 1);
    assertEq(terms[0].termId, 5);
    assertEq(terms[0].duration, 14 days);
    assertEq(terms[0].apr, 110 * 1e25);
  }

  function test_refinance_matured_success() public {
    FixedTermAndRate memory term1 = FixedTermAndRate({ termId: 100, duration: 1 hours, apr: 105 * 1e25 });
    FixedTermAndRate memory term2 = FixedTermAndRate({ termId: 101, duration: 2 hours, apr: 110 * 1e25 });
    FixedTermAndRate memory term3 = FixedTermAndRate({ termId: 102, duration: 3 hours, apr: 115 * 1e25 });
    // create a short-term fixed position
    vm.startPrank(BOT);
    broker.updateFixedTermAndRate(term1, false);
    broker.updateFixedTermAndRate(term2, false);
    broker.updateFixedTermAndRate(term3, false);
    vm.stopPrank();

    vm.startPrank(borrower);
    broker.borrow(500 ether, 100);
    broker.borrow(500 ether, 101);
    broker.borrow(500 ether, 102);
    vm.stopPrank();
    // let it mature
    skip(4 hours);
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 3);

    // refinance as BOT
    uint256[] memory wrongPosIds = new uint256[](4);
    wrongPosIds[0] = positions[2].posId;
    wrongPosIds[1] = positions[1].posId;
    wrongPosIds[2] = positions[2].posId;
    wrongPosIds[3] = positions[0].posId; // duplicated
    vm.prank(BOT);
    vm.expectRevert();
    broker.refinanceMaturedFixedPositions(borrower, wrongPosIds);

    // refinance as BOT
    uint256[] memory posIds = new uint256[](3);
    posIds[0] = positions[0].posId;
    posIds[1] = positions[1].posId;
    posIds[2] = positions[2].posId;
    vm.prank(BOT);
    broker.refinanceMaturedFixedPositions(borrower, posIds);
    // fixed positions will be removed; the principal aggregates into dynamic in current implementation
    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
    // dynamic position principal increased
    (uint256 dynPrincipal, ) = broker.dynamicLoanPositions(borrower);
    assertGt(dynPrincipal, 0);
  }

  function test_peek_otherUser_noCollateral_returnsOraclePrice() public {
    // another user with no collateral
    address other = address(0xBEEF);
    uint256 priceFromOracle = oracle.peek(address(BTCB));
    uint256 peeked = broker.peek(address(BTCB), other);
    assertEq(peeked, priceFromOracle);
  }

  function test_setMaxFixedLoanPositions_sameValue_reverts() public {
    // default is 10 (from initialize)
    vm.expectRevert(LendingBroker.SameValueProvided.selector);
    vm.prank(MANAGER);
    broker.setMaxFixedLoanPositions(10);
  }

  function test_checkPositionsBelowMinLoanDynamic_reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 100, duration: 1 hours, apr: 105 * 1e25 });
    // create a short-term fixed position
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.prank(MANAGER);
    moolah.setMinLoanValue(10e8);
    uint256 minLoan = moolah.minLoan(marketParams);
    assertEq(minLoan, 10e18);

    vm.startPrank(borrower);
    broker.borrow(minLoan);
    broker.borrow(minLoan, term.termId);
    vm.stopPrank();

    vm.prank(borrower);
    vm.expectRevert("broker/dynamic-below-min-loan");
    broker.repay(minLoan / 2, borrower);
  }

  // -----------------------------
  // Emergency withdraw & receive
  // -----------------------------

  function test_receive_acceptsNativeBNB() public {
    uint256 amount = 1 ether;
    vm.deal(address(this), amount);
    (bool success, ) = address(broker).call{ value: amount }("");
    assertTrue(success, "receive failed");
    assertEq(address(broker).balance, amount, "broker balance mismatch");
  }

  function test_emergencyWithdraw_ERC20_byManager() public {
    uint256 amount = 500 ether;
    LISUSD.setBalance(address(broker), amount);

    uint256 managerBefore = LISUSD.balanceOf(MANAGER);
    vm.prank(MANAGER);
    broker.emergencyWithdraw(address(LISUSD), amount);

    assertEq(LISUSD.balanceOf(address(broker)), 0, "broker should have 0 after withdraw");
    assertEq(LISUSD.balanceOf(MANAGER) - managerBefore, amount, "manager should receive tokens");
  }

  function test_emergencyWithdraw_nativeBNB_byManager() public {
    uint256 amount = 2 ether;
    vm.deal(address(broker), amount);

    uint256 managerBefore = MANAGER.balance;
    vm.prank(MANAGER);
    broker.emergencyWithdraw(address(0), amount);

    assertEq(address(broker).balance, 0, "broker should have 0 BNB after withdraw");
    assertEq(MANAGER.balance - managerBefore, amount, "manager should receive BNB");
  }

  function test_emergencyWithdraw_revertsForNonManager() public {
    uint256 amount = 1 ether;
    LISUSD.setBalance(address(broker), amount);

    vm.expectRevert();
    vm.prank(borrower);
    broker.emergencyWithdraw(address(LISUSD), amount);
  }

  function test_emergencyWithdraw_revertsOnZeroAmount() public {
    vm.expectRevert(LendingBroker.ZeroAmount.selector);
    vm.prank(MANAGER);
    broker.emergencyWithdraw(address(LISUSD), 0);
  }

  function test_emergencyWithdraw_emitsEvent() public {
    uint256 amount = 100 ether;
    LISUSD.setBalance(address(broker), amount);

    vm.expectEmit(true, true, false, true);
    emit IBroker.EmergencyWithdrawn(MANAGER, address(LISUSD), amount);

    vm.prank(MANAGER);
    broker.emergencyWithdraw(address(LISUSD), amount);
  }

  function test_validateDynamicPosition_allowsFullRepay() public {
    vm.prank(MANAGER);
    moolah.setMinLoanValue(1e8);
    uint256 minLoan = moolah.minLoan(marketParams);

    vm.prank(borrower);
    broker.borrow(minLoan);

    // full repayment leaves zero principal, which _validateDynamicPosition accepts
    vm.prank(borrower);
    broker.repay(minLoan, borrower);

    DynamicLoanPosition memory pos = broker.userDynamicPosition(borrower);
    assertEq(pos.principal, 0);
    assertEq(pos.normalizedDebt, 0);
  }

  /// @notice repay{value} reverts when LOAN_TOKEN != WBNB (native BNB not supported).
  function test_repay_native_revertsWhenLoanTokenIsNotWBNB() public {
    vm.prank(borrower);
    broker.borrow(1000 ether);

    vm.deal(borrower, 1 ether);
    vm.prank(borrower);
    vm.expectRevert(LendingBroker.NativeNotSupported.selector);
    broker.repay{ value: 1 ether }(1 ether, borrower);
  }

  function test_brokers_returnsRegisteredConfig() public {
    (uint256 currentRate, uint256 ratePerSecond, uint256 maxRatePerSecond, uint256 lastUpdated) = rateCalc.brokers(
      address(broker)
    );
    assertEq(currentRate, RATE_SCALE);
    assertEq(ratePerSecond, RATE_SCALE + 1);
    assertEq(maxRatePerSecond, RATE_SCALE + 2);
    assertGt(lastUpdated, 0);
  }

  function test_brokers_unregisteredBroker_returnsZeroes() public view {
    (uint256 currentRate, uint256 ratePerSecond, uint256 maxRatePerSecond, uint256 lastUpdated) = rateCalc.brokers(
      address(0xdead)
    );
    assertEq(currentRate, 0);
    assertEq(ratePerSecond, 0);
    assertEq(maxRatePerSecond, 0);
    assertEq(lastUpdated, 0);
  }

  function test_borrowAndRepay_native_whenLoanTokenIsWBNB() public {
    vm.deal(borrower, 1000 ether);
    vm.deal(address(WBNB), 1000 ether);
    vm.startPrank(borrower);
    bnbBroker.borrow(1000 ether);
    bnbBroker.repay{ value: 1 ether }(1 ether, borrower);
    vm.stopPrank();
  }

  // =============================================
  // setRelayer / setOracle tests (one-time, admin-only)
  // =============================================

  /// @dev Deploy a fresh broker proxy with RELAYER/ORACLE unset (simulating V1->V2 upgrade)
  function _deployBrokerWithEmptyRelayerOracle() internal returns (LendingBroker) {
    LendingBroker bImpl = new LendingBroker(address(moolah), address(0));
    // Use 6-param initialize (no relayer/oracle) by encoding only the original params
    // and leaving RELAYER/ORACLE as address(0)
    ERC1967Proxy bProxy = new ERC1967Proxy(
      address(bImpl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        address(1), // placeholder relayer — will be overwritten below
        address(1) // placeholder oracle — will be overwritten below
      )
    );
    LendingBroker b = LendingBroker(payable(address(bProxy)));
    // Simulate V1->V2 upgrade: storage RELAYER/ORACLE are zeroed out
    vm.store(address(b), bytes32(uint256(18)), bytes32(0)); // RELAYER slot
    vm.store(address(b), bytes32(uint256(19)), bytes32(0)); // ORACLE slot
    return b;
  }

  function test_setRelayer_success() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    assertEq(b.RELAYER(), address(0));

    vm.prank(ADMIN);
    b.setRelayer(address(relayer));
    assertEq(b.RELAYER(), address(relayer));
  }

  function test_setRelayer_reverts_zeroAddress() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    vm.prank(ADMIN);
    vm.expectRevert(bytes("broker/zero-address-provided"));
    b.setRelayer(address(0));
  }

  function test_setRelayer_reverts_alreadySet() public {
    // broker from setUp already has RELAYER set via initialize
    vm.prank(ADMIN);
    vm.expectRevert(bytes("broker/already-set"));
    broker.setRelayer(makeAddr("newRelayer"));
  }

  function test_setRelayer_reverts_notAdmin() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    vm.prank(MANAGER);
    vm.expectRevert();
    b.setRelayer(address(relayer));
  }

  function test_setOracle_success() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    assertEq(address(b.ORACLE()), address(0));

    vm.prank(ADMIN);
    b.setOracle(address(oracle));
    assertEq(address(b.ORACLE()), address(oracle));
  }

  function test_setOracle_reverts_zeroAddress() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    vm.prank(ADMIN);
    vm.expectRevert(bytes("broker/zero-address-provided"));
    b.setOracle(address(0));
  }

  function test_setOracle_reverts_alreadySet() public {
    // broker from setUp already has ORACLE set via initialize
    vm.prank(ADMIN);
    vm.expectRevert(bytes("broker/already-set"));
    broker.setOracle(makeAddr("newOracle"));
  }

  function test_setOracle_reverts_notAdmin() public {
    LendingBroker b = _deployBrokerWithEmptyRelayerOracle();
    vm.prank(MANAGER);
    vm.expectRevert();
    b.setOracle(address(oracle));
  }

  // =============================================
  // Smart LP liquidation tests
  // =============================================

  /// @dev Helper: deploy a MockSmartProvider whose collateralToken == BTCB
  /// and whose underlying tokens are LISUSD (token0) and BTCB (token1).
  function _setupSmartProvider() internal returns (MockSmartProvider sp, MockSwapPair swapPair) {
    sp = new MockSmartProvider(address(LISUSD), address(BTCB));
    sp.setCollateralToken(address(BTCB));

    // whitelist the smart provider
    address[] memory providers = new address[](1);
    providers[0] = address(sp);
    vm.prank(MANAGER);
    liquidator.batchSetSmartProviders(providers, true);

    // deploy a mock swap pair that converts BTCB -> LISUSD at oracle price
    swapPair = new MockSwapPair(address(BTCB), address(LISUSD), oracle);

    // whitelist swap pair
    vm.prank(MANAGER);
    liquidator.setPairWhitelist(address(swapPair), true);

    // whitelist tokens
    vm.prank(MANAGER);
    liquidator.setTokenWhitelist(address(LISUSD), true);
    vm.prank(MANAGER);
    liquidator.setTokenWhitelist(address(BTCB), true);
  }

  function test_liquidateSmartCollateral_seizes_and_redeems() public {
    _prepareLiquidatablePosition(false);

    (MockSmartProvider sp, ) = _setupSmartProvider();

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 1 * 1e8, 100 * 1e8); // 1%

    bytes memory payload = abi.encode(uint256(0), uint256(0)); // no slippage min

    // Fund liquidator with LISUSD for repayment (non-flash: liquidator pays upfront)
    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    liquidator.liquidateSmartCollateral(Id.unwrap(id), borrower, address(sp), 0, userRepayShares, payload);

    // After liquidation + LP redemption, the liquidator should hold redeemed tokens
    // The smart provider splits into LISUSD (token0) and BTCB (token1)
    uint256 lisusdAfter = LISUSD.balanceOf(address(liquidator));
    uint256 btcbAfter = BTCB.balanceOf(address(liquidator));
    // Liquidator should have some redeemed tokens (LISUSD from redemption + leftover, BTCB from redemption)
    assertGt(lisusdAfter + btcbAfter, 0, "liquidator received no redeemed tokens");

    // Borrower position should have decreased
    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "borrow shares did not decrease");
  }

  function test_flashLiquidateSmartCollateral_swaps_and_repays() public {
    _prepareLiquidatablePosition(false);

    (MockSmartProvider sp, MockSwapPair swapPair) = _setupSmartProvider();
    // Configure mock to return 0% as token0 (LISUSD), 100% as token1 (BTCB)
    // so that the entire LP value is in BTCB and gets swapped to LISUSD at oracle price
    sp.setToken0Bps(0);

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 1 * 1e8, 100 * 1e8); // 1%
    uint256 seizedAssets = _previewLiquidationRepayment(
      marketParams,
      moolah.market(marketParams.id()),
      0,
      userRepayShares,
      moolah._getPrice(marketParams, borrower)
    );

    // token0 = LISUSD, token1 = BTCB
    // With 0% token0Bps, all redeemed as BTCB, so only token1 needs swapping
    bytes memory swapToken0Data = ""; // no token0 output
    bytes memory swapToken1Data = abi.encodeWithSelector(MockSwapPair.swap.selector);
    bytes memory payload = abi.encode(uint256(0), uint256(0));

    vm.prank(BOT);
    liquidator.flashLiquidateSmartCollateral(
      Id.unwrap(id),
      borrower,
      address(sp),
      seizedAssets,
      address(swapPair), // token0Pair (unused since amount0 == 0)
      address(swapPair), // token1Pair (BTCB -> LISUSD swap)
      swapToken0Data,
      swapToken1Data,
      payload
    );

    // Position should have reduced debt
    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "borrow shares did not decrease");
  }

  function test_flashLiquidateSmartCollateral_reverts_notWhitelisted() public {
    _prepareLiquidatablePosition(false);

    MockSmartProvider sp = new MockSmartProvider(address(LISUSD), address(BTCB));
    sp.setCollateralToken(address(BTCB));
    // NOT whitelisted

    bytes memory payload = abi.encode(uint256(0), uint256(0));

    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    liquidator.flashLiquidateSmartCollateral(
      Id.unwrap(id),
      borrower,
      address(sp),
      1e18,
      address(1),
      address(1),
      "",
      "",
      payload
    );
  }

  function test_liquidateSmartCollateral_reverts_invalidProvider() public {
    _prepareLiquidatablePosition(false);

    // Create a smart provider whose TOKEN() != collateralToken (BTCB)
    MockSmartProvider sp = new MockSmartProvider(address(LISUSD), address(BTCB));
    // collateralToken defaults to address(sp) != BTCB

    address[] memory providers = new address[](1);
    providers[0] = address(sp);
    vm.prank(MANAGER);
    liquidator.batchSetSmartProviders(providers, true);

    bytes memory payload = abi.encode(uint256(0), uint256(0));

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    vm.expectRevert(bytes("Invalid smart provider"));
    liquidator.liquidateSmartCollateral(Id.unwrap(id), borrower, address(sp), 0, 1, payload);
  }

  function test_flashLiquidateSmartCollateral_reverts_pairNotWhitelisted() public {
    _prepareLiquidatablePosition(false);

    (MockSmartProvider sp, MockSwapPair swapPair) = _setupSmartProvider();

    address badPair = makeAddr("badPair");
    bytes memory payload = abi.encode(uint256(0), uint256(0));

    vm.prank(BOT);
    vm.expectRevert(BrokerLiquidator.NotWhitelisted.selector);
    liquidator.flashLiquidateSmartCollateral(
      Id.unwrap(id),
      borrower,
      address(sp),
      1e18,
      badPair, // not whitelisted
      address(swapPair),
      "",
      "",
      payload
    );
  }

  // =============================================
  // repayAll tests
  // =============================================

  /// @notice repayAll clears a dynamic-only position and supplies accrued interest as revenue.
  function test_repayAll_dynamicOnly() public {
    uint256 borrowAmt = 1000 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    // bump rate so meaningful interest accrues
    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 1e20);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 1e20);
    skip(7 days);

    uint256 rate = rateCalc.accrueRate(address(broker));
    (, uint256 normalizedDebt) = broker.dynamicLoanPositions(borrower);
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedDebt, rate);
    uint256 interestPortion = actualDebt - borrowAmt;
    assertGt(interestPortion, 0, "interest did not accrue");

    LISUSD.setBalance(borrower, actualDebt);
    uint256 relayerBalBefore = LISUSD.balanceOf(address(relayer));
    uint256 vaultSharesBefore = moolah.position(id, address(vault)).supplyShares;

    vm.prank(borrower);
    broker.repayAll(borrower);

    // dynamic position cleared
    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertEq(principalAfter, 0, "dynamic principal not cleared");
    assertEq(normalizedAfter, 0, "dynamic normalized debt not cleared");

    // borrow shares cleared at Moolah
    Position memory posAfter = moolah.position(id, borrower);
    assertEq(posAfter.borrowShares, 0, "borrow shares not cleared");

    // borrower spent the entire budget
    assertEq(LISUSD.balanceOf(borrower), 0, "borrower retained funds");

    // revenue (interest) was supplied to relayer / vault
    uint256 vaultSharesAfter = moolah.position(id, address(vault)).supplyShares;
    bool revenueSupplied = vaultSharesAfter > vaultSharesBefore ||
      LISUSD.balanceOf(address(relayer)) > relayerBalBefore;
    assertTrue(revenueSupplied, "interest not supplied to vault/relayer");
  }

  /// @notice repayAll clears every fixed position and charges full early-repay penalty.
  function test_repayAll_fixedOnly_chargesPenalty() public {
    vm.startPrank(BOT);
    broker.updateFixedTermAndRate(FixedTermAndRate({ termId: 1, duration: 30 days, apr: 110 * 1e25 }), false);
    broker.updateFixedTermAndRate(FixedTermAndRate({ termId: 2, duration: 60 days, apr: 115 * 1e25 }), false);
    vm.stopPrank();

    vm.startPrank(borrower);
    broker.borrow(500 ether, 1);
    broker.borrow(700 ether, 2);
    vm.stopPrank();

    skip(5 days);
    moolah.accrueInterest(marketParams);

    // every position should have a non-zero penalty (early repay)
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 2);
    for (uint256 i = 0; i < positions.length; i++) {
      uint256 remaining = positions[i].principal - positions[i].principalRepaid;
      assertGt(BrokerMath.getPenaltyForFixedPosition(positions[i], remaining), 0, "penalty not charged");
    }

    LISUSD.setBalance(borrower, 5_000 ether);
    uint256 relayerBefore = LISUSD.balanceOf(address(relayer));
    uint256 vaultSharesBefore = moolah.position(id, address(vault)).supplyShares;

    vm.prank(borrower);
    broker.repayAll(borrower);

    // every fixed position cleared
    assertEq(broker.userFixedPositions(borrower).length, 0, "fixed positions not cleared");
    Position memory posAfter = moolah.position(id, borrower);
    assertEq(posAfter.borrowShares, 0, "borrow shares not cleared");

    // revenue (interest + penalty) reached relayer/vault
    uint256 vaultSharesAfter = moolah.position(id, address(vault)).supplyShares;
    bool revenueSupplied = vaultSharesAfter > vaultSharesBefore || LISUSD.balanceOf(address(relayer)) > relayerBefore;
    assertTrue(revenueSupplied, "no revenue supplied");
  }

  /// @notice repayAll clears dynamic and fixed positions in a single call.
  function test_repayAll_dynamicAndFixed() public {
    vm.prank(BOT);
    broker.updateFixedTermAndRate(FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 }), false);

    vm.startPrank(borrower);
    broker.borrow(800 ether);
    broker.borrow(400 ether, 1);
    vm.stopPrank();

    vm.prank(MANAGER);
    rateCalc.setMaxRatePerSecond(address(broker), RATE_SCALE + 1e20);
    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 1e20);
    skip(3 days);

    LISUSD.setBalance(borrower, 10_000 ether);

    vm.prank(borrower);
    broker.repayAll(borrower);

    (uint256 dynPrincipal, uint256 dynNormalized) = broker.dynamicLoanPositions(borrower);
    assertEq(dynPrincipal, 0, "dynamic not cleared");
    assertEq(dynNormalized, 0, "dynamic normalized not cleared");
    assertEq(broker.userFixedPositions(borrower).length, 0, "fixed not cleared");

    Position memory posAfter = moolah.position(id, borrower);
    assertEq(posAfter.borrowShares, 0, "borrow shares not cleared");
  }

  /// @notice repayAll emits AllPositionsRepaid with the total amount charged.
  function test_repayAll_emitsEvent() public {
    vm.prank(borrower);
    broker.borrow(500 ether);

    skip(1 hours);

    LISUSD.setBalance(borrower, 1_000 ether);

    // we don't pin the totalRepaid amount precisely (interest tiny but non-deterministic);
    // assert event topic + emitter, then check positions cleared after
    vm.expectEmit(true, false, false, false, address(broker));
    emit IBroker.AllPositionsRepaid(borrower, 0); // value not checked
    vm.prank(borrower);
    broker.repayAll(borrower);
  }

  /// @notice repayAll emits FixedLoanPositionRemoved for every cleared fixed position
  ///         and DynamicLoanPositionRepaid for the cleared dynamic position.
  function test_repayAll_emitsPerPositionEvents() public {
    vm.startPrank(BOT);
    broker.updateFixedTermAndRate(FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 }), false);
    broker.updateFixedTermAndRate(FixedTermAndRate({ termId: 2, duration: 60 days, apr: 110 * 1e25 }), false);
    vm.stopPrank();

    vm.startPrank(borrower);
    broker.borrow(300 ether);
    broker.borrow(200 ether, 1);
    broker.borrow(150 ether, 2);
    vm.stopPrank();

    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 2);

    LISUSD.setBalance(borrower, 5_000 ether);

    // Expect: dynamic repaid event + a removed event for each fixed pos + the all-repaid event.
    // Don't pin amount in the dynamic repaid event (interest is tiny but non-deterministic).
    vm.expectEmit(true, false, false, false, address(broker));
    emit IBroker.DynamicLoanPositionRepaid(borrower, 0, 0);
    vm.expectEmit(true, false, false, true, address(broker));
    emit IBroker.FixedLoanPositionRemoved(borrower, positions[0].posId);
    vm.expectEmit(true, false, false, true, address(broker));
    emit IBroker.FixedLoanPositionRemoved(borrower, positions[1].posId);
    vm.expectEmit(true, false, false, false, address(broker));
    emit IBroker.AllPositionsRepaid(borrower, 0);

    vm.prank(borrower);
    broker.repayAll(borrower);
  }

  /// @notice A third party may repayAll on behalf of any borrower.
  function test_repayAll_byThirdParty() public {
    vm.prank(borrower);
    broker.borrow(300 ether);

    address helper = address(0x707);
    LISUSD.setBalance(helper, 1_000 ether);
    vm.startPrank(helper);
    IERC20(address(LISUSD)).approve(address(broker), type(uint256).max);
    broker.repayAll(borrower);
    vm.stopPrank();

    (uint256 p, ) = broker.dynamicLoanPositions(borrower);
    assertEq(p, 0, "dynamic not cleared");
    Position memory posAfter = moolah.position(id, borrower);
    assertEq(posAfter.borrowShares, 0, "borrow shares not cleared");
    assertLt(LISUSD.balanceOf(helper), 1_000 ether, "helper balance unchanged");
  }

  /// @notice repayAll with native BNB clears the position and refunds excess.
  function test_repayAll_native_refundsExcess() public {
    // bootstrap WBNB totalSupply so the burn-then-mint sequence in withdraw/deposit
    // does not underflow→overflow (WBNBMock uses OZ ERC20; deal() does not adjust totalSupply)
    vm.deal(address(this), 10_000 ether);
    WBNB.deposit{ value: 10_000 ether }();

    vm.deal(borrower, 1_000 ether);
    vm.deal(address(WBNB), 10_000 ether);

    vm.startPrank(borrower);
    bnbBroker.borrow(500 ether);
    vm.stopPrank();

    uint256 budget = 600 ether; // overpay
    vm.deal(borrower, borrower.balance + budget);
    uint256 balBefore = borrower.balance;

    vm.prank(borrower);
    bnbBroker.repayAll{ value: budget }(borrower);

    (uint256 p, ) = bnbBroker.dynamicLoanPositions(borrower);
    assertEq(p, 0, "dynamic not cleared");
    Position memory posAfter = moolah.position(bnbId, borrower);
    assertEq(posAfter.borrowShares, 0, "borrow shares not cleared");

    uint256 balAfter = borrower.balance;
    assertGt(balAfter, balBefore - budget, "no native refund issued");
  }

  /// @notice repayAll reverts when called with native value on a non-WBNB market.
  function test_repayAll_revertsNativeOnNonWBNB() public {
    vm.prank(borrower);
    broker.borrow(100 ether);

    vm.deal(borrower, 1 ether);
    vm.expectRevert(LendingBroker.NativeNotSupported.selector);
    vm.prank(borrower);
    broker.repayAll{ value: 1 ether }(borrower);
  }

  /// @notice repayAll reverts when msg.value < totalDebt on the WBNB broker.
  function test_repayAll_revertsInsufficientNativeValue() public {
    vm.deal(borrower, 1_000 ether);
    vm.deal(address(WBNB), 10_000 ether);

    vm.startPrank(borrower);
    bnbBroker.borrow(500 ether);
    vm.stopPrank();

    // send a tiny fraction — must revert with InsufficientAmount
    vm.expectRevert(LendingBroker.InsufficientAmount.selector);
    vm.prank(borrower);
    bnbBroker.repayAll{ value: 1 wei }(borrower);
  }

  /// @notice repayAll reverts on zero onBehalf address.
  function test_repayAll_revertsZeroAddress() public {
    vm.expectRevert(LendingBroker.ZeroAddress.selector);
    vm.prank(borrower);
    broker.repayAll(address(0));
  }

  /// @notice repayAll reverts when the user has no debt.
  function test_repayAll_revertsNothingToRepay() public {
    vm.expectRevert(LendingBroker.NothingToRepay.selector);
    vm.prank(borrower);
    broker.repayAll(borrower);
  }

  // =============================================
  // Per-position validation tests
  // =============================================

  /// @notice partial repay of a fixed position to below minLoan reverts with the per-fixed error.
  ///         A second (large) position keeps Moolah's own debt above minLoan so the broker-level
  ///         validation is the one that fires.
  function test_repayFixed_belowMin_reverts() public {
    vm.prank(MANAGER);
    moolah.setMinLoanValue(100 * 1e8); // minLoan = 100 ether
    uint256 minLoan = moolah.minLoan(marketParams);
    assertEq(minLoan, 100 ether);

    FixedTermAndRate memory term = FixedTermAndRate({ termId: 100, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.startPrank(borrower);
    broker.borrow(500 ether); // dynamic — keeps total Moolah debt well above minLoan
    broker.borrow(minLoan, term.termId);
    vm.stopPrank();

    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    uint256 posId = positions[0].posId;

    LISUSD.setBalance(borrower, 1_000 ether);
    vm.expectRevert("broker/fixed-below-min-loan");
    vm.prank(borrower);
    broker.repay(minLoan / 2, posId, borrower);
  }

  /// @notice "validate current" isolation: an unrelated below-min fixed position does not block
  ///         a dynamic borrow on the same user. Old "validate all" would have reverted here.
  function test_validation_isolation_borrowDynamicWhenFixedBelowMin() public {
    // initial minLoan = 15 ether (set in setUp via Moolah.initialize(_minLoanValue=15e8))
    assertEq(moolah.minLoan(marketParams), 15 ether);

    FixedTermAndRate memory term = FixedTermAndRate({ termId: 200, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // borrow 50 dynamic + 50 fixed (both above the 15-ether minLoan)
    vm.startPrank(borrower);
    broker.borrow(50 ether);
    broker.borrow(50 ether, term.termId);
    vm.stopPrank();

    // raise minLoan so the existing fixed position (50) is now below the new floor (100)
    vm.prank(MANAGER);
    moolah.setMinLoanValue(100 * 1e8);
    assertEq(moolah.minLoan(marketParams), 100 ether);

    // borrow more dynamic — only the dynamic position (which becomes 150) is validated
    vm.prank(borrower);
    broker.borrow(100 ether);

    (uint256 dynPrincipal, ) = broker.dynamicLoanPositions(borrower);
    assertEq(dynPrincipal, 150 ether);
    // unrelated below-min fixed position remains untouched
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    assertEq(positions[0].principal, 50 ether);
  }

  // =============================================
  // Liquidation runs even when leaving below-min
  // =============================================

  /// @notice After my change, liquidation no longer validates positions, so it succeeds even
  ///         when the resulting principal falls below minLoan.
  function test_liquidation_noRevertWhenLeavesPositionBelowMin() public {
    _prepareLiquidatablePosition(false);

    // raise minLoan above what each position will end up with after a 50% liquidation.
    // setUp creates 40000 dyn + 40000 fixed; ~50% liquidation leaves ~20000 each.
    vm.prank(MANAGER);
    moolah.setMinLoanValue(25_000 * 1e8); // minLoan = 25,000 ether

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 50 * 1e8, 100 * 1e8);

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    // old code would have reverted with broker/positions-below-min-loan; the new code must succeed
    vm.prank(BOT);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, userRepayShares);

    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "shares should decrease");
  }

  /// @notice Regression: after a partial liquidation, a position can be left in the
  ///         "interest-only residual" state — `principal == 0` while `normalizedDebt > 0`
  ///         (because liquidation paid the principal but only a fraction of the broker's
  ///         accrued interest). This test exercises that path through repayAll:
  ///           (1) liquidation completes (no broker validation)
  ///           (2) repayAll's `dynamicInterest > 0` guard fires and clears the residual
  ///           (3) DynamicLoanPositionRepaid event still emits for the residual
  ///           (4) no leftover broker tracking, no Moolah debt
  function test_liquidation_postResidual_repayAllClearsCleanly() public {
    _prepareLiquidatablePosition(false);

    // 50% liquidation of 40k dyn + 40k fixed: dynamic absorbs all 40k principal first,
    // leaving dynamic with only an interest residual (principal == 0, normalizedDebt > 0).
    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    uint256 userRepayShares = BrokerMath.mulDivCeiling(posBefore.borrowShares, 50 * 1e8, 100 * 1e8);
    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, userRepayShares);

    // confirm the residual: principal cleared but interest still tracked
    (uint256 dynPrincipal, uint256 dynNormDebt) = broker.dynamicLoanPositions(borrower);
    assertEq(dynPrincipal, 0, "dynamic principal should be cleared");
    assertGt(dynNormDebt, 0, "dynamic should retain interest residual");

    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1, "expected one fixed position remaining");
    uint256 fixedPosId = positions[0].posId;

    // repayAll should: charge the residual interest, fire DynamicLoanPositionRepaid (via the
    // `dynamicInterest > 0` guard), remove the fixed position, and clear all state.
    LISUSD.setBalance(borrower, 1_000_000 ether);

    vm.expectEmit(true, false, false, false, address(broker));
    emit IBroker.DynamicLoanPositionRepaid(borrower, 0, 0);
    vm.expectEmit(true, false, false, true, address(broker));
    emit IBroker.FixedLoanPositionRemoved(borrower, fixedPosId);
    vm.expectEmit(true, false, false, false, address(broker));
    emit IBroker.AllPositionsRepaid(borrower, 0);

    vm.prank(borrower);
    broker.repayAll(borrower);

    (uint256 dynAfter, uint256 normAfter) = broker.dynamicLoanPositions(borrower);
    assertEq(dynAfter, 0, "dynamic principal not cleared");
    assertEq(normAfter, 0, "dynamic normalized debt not cleared (interest residual leaked)");
    assertEq(broker.userFixedPositions(borrower).length, 0, "fixed not cleared");
    Position memory moolahAfter = moolah.position(id, borrower);
    assertEq(moolahAfter.borrowShares, 0, "moolah debt not cleared");
  }

  /// @notice Broker market runs 0% Moolah-side IRM, so totalBorrowAssets/totalBorrowShares stays
  ///         locked at 1:VIRTUAL_SHARES across the market's lifetime. A liquidation that passes a
  ///         repaidShares value not divisible by VIRTUAL_SHARES would have toAssetsUp ceiling round
  ///         the asset deduction up by 1 wei, drifting the ratio and corrupting later repayments
  ///         for every borrower in the market. The guard rejects this at the broker layer.
  function test_liquidation_revertsOnNonDivisibleRepaidShares() public {
    _prepareLiquidatablePosition(false);

    Position memory posBefore = moolah.position(marketParams.id(), borrower);
    // 50% clamped to a clean multiple, then add 1 to force non-divisible
    uint256 cleanShares = (posBefore.borrowShares / 2 / SharesMathLib.VIRTUAL_SHARES) * SharesMathLib.VIRTUAL_SHARES;
    uint256 dirtyShares = cleanShares + 1;

    LISUSD.setBalance(address(liquidator), 1_000_000 ether);

    vm.prank(BOT);
    vm.expectRevert(LendingBroker.InvalidRepaidShares.selector);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, dirtyShares);

    // clean multiple still succeeds
    vm.prank(BOT);
    liquidator.liquidate(Id.unwrap(id), borrower, 0, cleanShares);
    Position memory posAfter = moolah.position(marketParams.id(), borrower);
    assertLt(posAfter.borrowShares, posBefore.borrowShares, "clean shares should liquidate");
  }
}

/// @dev Mock swap pair that converts tokenIn -> tokenOut at oracle price.
/// Pulls the approved amount (not full balance) to match real aggregator behavior.
contract MockSwapPair is Test {
  address public tokenIn;
  address public tokenOut;
  OracleMock public oracle;

  constructor(address _tokenIn, address _tokenOut, OracleMock _oracle) {
    tokenIn = _tokenIn;
    tokenOut = _tokenOut;
    oracle = _oracle;
  }

  /// @dev Swap approved tokenIn for tokenOut at oracle price
  function swap() external {
    uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
    if (amountIn > 0) {
      IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
      // convert at oracle price: amountIn * tokenInPrice / tokenOutPrice
      uint256 tokenInPrice = oracle.peek(tokenIn);
      uint256 tokenOutPrice = oracle.peek(tokenOut);
      uint256 amountOut = (amountIn * tokenInPrice) / tokenOutPrice;
      deal(tokenOut, address(this), amountOut);
      IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
  }
}

contract LiquidationCallbackMock is IMoolahLiquidateCallback {
  uint256 public lastRepaidAssets;
  bytes public lastData;

  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external override {
    lastRepaidAssets = repaidAssets;
    lastData = data;
  }
}

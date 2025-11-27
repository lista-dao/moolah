// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMockZero } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";

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
import { MockLiquidator } from "./MockLiquidator.sol";
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
  RateCalculator public rateCalc;
  MoolahVault public vault;
  BrokerInterestRelayer public relayer;

  // Market commons
  MarketParams public marketParams;
  Id public id;

  // Token handles (real tokens on fork or mocks locally if used)
  OracleMock public oracle; // unused in fork path
  IrmMockZero public irm; // unused in fork path
  address supplier = address(0x201);
  address borrower = address(0x202);
  MockLiquidator public liquidator;

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

    // Oracle with initial prices
    oracle = new OracleMock();
    oracle.setPrice(address(LISUSD), 1e8);
    oracle.setPrice(address(BTCB), 120000e8);

    // IRM enable + LLTV
    irm = new IrmMockZero();
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableLltv(80 * 1e16); // 80%

    // Vault (only used as supply receiver for interest in tests)
    vault = new MoolahVault(address(moolah), address(LISUSD));

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

    // RateCalculator proxy
    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    rateCalc = RateCalculator(address(rcProxy));

    // Deploy LendingBroker proxy first (used as oracle by the market)
    LendingBroker bImpl = new LendingBroker(address(moolah), address(relayer), address(oracle));
    ERC1967Proxy bProxy = new ERC1967Proxy(
      address(bImpl),
      abi.encodeWithSelector(LendingBroker.initialize.selector, ADMIN, MANAGER, BOT, PAUSER, address(rateCalc), 10)
    );
    broker = LendingBroker(payable(address(bProxy)));

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

    // Bind broker to market id
    vm.prank(MANAGER);
    broker.setMarketId(id);

    // Register broker and set as market broker (for user-aware pricing)
    vm.startPrank(MANAGER);
    rateCalc.registerBroker(address(broker), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(id, address(broker), true);
    vm.stopPrank();

    // Seed market liquidity
    uint256 seed = SUPPLY_LIQ;
    LISUSD.setBalance(supplier, seed);
    vm.startPrank(supplier);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    moolah.supply(marketParams, seed, 0, supplier, bytes(""));
    vm.stopPrank();

    // Fund borrower with collateral and deposit to Moolah
    BTCB.setBalance(borrower, COLLATERAL);
    vm.startPrank(borrower);
    BTCB.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(marketParams, COLLATERAL, borrower, bytes(""));
    vm.stopPrank();

    // Approval for borrower -> broker (for future repay)
    vm.prank(borrower);
    LISUSD.approve(address(broker), type(uint256).max);

    // deploy liquidator contract
    MockLiquidator mockLiqImpl = new MockLiquidator(address(moolah));
    ERC1967Proxy mockLiqProxy = new ERC1967Proxy(
      address(mockLiqImpl),
      abi.encodeWithSelector(MockLiquidator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    liquidator = MockLiquidator(address(mockLiqProxy));

    // whitelist lendingbroker as liquidator in moolah
    Id[] memory ids = new Id[](1);
    ids[0] = id;
    address[][] memory accounts = new address[][](1);
    accounts[0] = new address[](1);
    accounts[0][0] = address(broker);
    vm.prank(MANAGER);
    Moolah(address(moolah)).batchToggleLiquidationWhitelist(ids, accounts, true);

    // whitelist liquidator at lending broker
    vm.prank(MANAGER);
    broker.toggleLiquidationWhitelist(address(liquidator), true);

    // add broker into relayer
    vm.prank(MANAGER);
    relayer.addBroker(address(broker));

    // add brokers mapping in liquidator
    vm.prank(MANAGER);
    liquidator.setBroker(Id.unwrap(id), address(broker), true);
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

    uint256 convertAmount = 400 ether;
    uint256 expectedInterestShare = outstandingInterest == 0
      ? 0
      : BrokerMath.mulDivCeiling(outstandingInterest, convertAmount, principalBefore);
    uint256 expectedNormalizedDelta = BrokerMath.normalizeBorrowAmount(
      convertAmount + expectedInterestShare,
      rate,
      true
    );
    uint256 expectedNormalizedAfter = normalizedBefore > expectedNormalizedDelta
      ? normalizedBefore - expectedNormalizedDelta
      : 0;

    vm.prank(borrower);
    broker.convertDynamicToFixed(convertAmount, 51);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertEq(principalAfter, principalBefore - convertAmount, "dynamic principal not reduced by amount");
    assertApproxEqAbs(normalizedAfter, expectedNormalizedAfter, 1, "normalized debt delta mismatch");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1, "fixed position not created");
    assertEq(fixedPositions[0].principal, convertAmount + expectedInterestShare, "converted fixed principal incorrect");
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
    uint256 expectedNormalizedDelta = BrokerMath.normalizeBorrowAmount(actualDebt, rate, true);

    vm.prank(borrower);
    broker.convertDynamicToFixed(principalBefore, 52);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertApproxEqAbs(principalAfter, 0, 1, "dynamic principal should be cleared");
    assertApproxEqAbs(normalizedAfter, 0, 1, "dynamic normalized debt should be cleared");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1);
    assertApproxEqAbs(
      fixedPositions[0].principal,
      principalBefore + outstandingInterest,
      1,
      "fixed principal should equal full outstanding debt"
    );

    // sanity: normalized delta consumed the whole normalized debt (allowing rounding wiggle)
    assertApproxEqAbs(expectedNormalizedDelta, normalizedBefore, 1, "normalized debt delta rounding");
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
    vm.expectRevert(bytes("broker/zero-amount"));
    vm.prank(borrower);
    broker.borrow(0);
  }

  function test_borrowFixedTermNotFound_Reverts() public {
    vm.expectRevert(bytes("broker/term-not-found"));
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
    vm.expectRevert(bytes("broker/same-value-provided"));
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);
  }

  function test_borrowDynamic_whenPaused_reverts() public {
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);

    vm.expectRevert(bytes("Broker/borrow-paused"));
    vm.prank(borrower);
    broker.borrow(1 ether);
  }

  function test_borrowFixed_whenPaused_reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 111, duration: 30 days, apr: 105 * 1e25 });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);

    vm.expectRevert(bytes("Broker/borrow-paused"));
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
    vm.expectRevert(bytes("broker/exceed-max-fixed-positions"));
    broker.borrow(15 ether, 11);
    vm.stopPrank();
  }

  function test_peekLoanToken_OneE8() public {
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 1e8);
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
    vm.expectRevert(bytes("broker/unsupported-token"));
    broker.peek(address(0xDEA), borrower);
  }

  function test_marketIdSet_guard_reverts() public {
    // Deploy a second broker without setting market id
    LendingBroker bImpl2 = new LendingBroker(address(moolah), address(vault), address(oracle));
    ERC1967Proxy bProxy2 = new ERC1967Proxy(
      address(bImpl2),
      abi.encodeWithSelector(LendingBroker.initialize.selector, ADMIN, MANAGER, BOT, PAUSER, address(rateCalc), 10)
    );
    LendingBroker broker2 = LendingBroker(payable(address(bProxy2)));
    vm.expectRevert(bytes("Broker/market-not-set"));
    vm.prank(borrower);
    broker2.borrow(1 ether);
  }

  function test_setMarketId_onlyOnce_reverts() public {
    vm.expectRevert(bytes("broker/invalid-market"));
    vm.prank(MANAGER);
    broker.setMarketId(id);
  }

  function test_setFixedTerm_validations_revert() public {
    FixedTermAndRate memory term1 = FixedTermAndRate({ termId: 0, duration: 30 days, apr: 105 * 1e25 });
    FixedTermAndRate memory term2 = FixedTermAndRate({ termId: 1, duration: 0, apr: 105 * 1e25 });
    FixedTermAndRate memory term3 = FixedTermAndRate({ termId: 2, duration: 90 days, apr: 0 });
    // termId = 0
    vm.expectRevert(bytes("broker/invalid-term-id"));
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term1, false);
    // duration = 0
    vm.expectRevert(bytes("broker/invalid-duration"));
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term2, false);
    // apr < RATE_SCALE
    vm.expectRevert(bytes("broker/invalid-apr"));
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
    vm.expectRevert(bytes("broker/term-not-found"));
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
    vm.expectRevert(bytes("broker/same-value-provided"));
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
    vm.expectRevert("broker/positions-below-min-loan");
    broker.repay(minLoan / 2, borrower);
  }

  function test_checkPositionsMeetsMinLoan_allowsFullRepay() public {
    vm.prank(MANAGER);
    moolah.setMinLoanValue(1e8);
    uint256 minLoan = moolah.minLoan(marketParams);

    vm.prank(borrower);
    broker.borrow(minLoan);

    // full repayment leaves zero debt, which BrokerMath.checkPositionsMeetsMinLoan accepts
    vm.prank(borrower);
    broker.repay(minLoan, borrower);

    DynamicLoanPosition memory pos = broker.userDynamicPosition(borrower);
    assertEq(pos.principal, 0);
    assertEq(pos.normalizedDebt, 0);
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

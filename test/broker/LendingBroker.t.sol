// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMock } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";
import { IRateCalculator } from "../../src/broker/interfaces/IRateCalculator.sol";
import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate } from "../../src/broker/interfaces/IBroker.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketAllocation } from "../../src/moolah-vault/interfaces/IMoolahVault.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";
import { ORACLE_PRICE_SCALE } from "moolah/libraries/ConstantsLib.sol";

contract LendingBrokerTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;

  // ========= Shared state (unused fields may remain default in some tests) =========
  // Core
  IMoolah public moolah;
  LendingBroker public broker;
  RateCalculator public rateCalc;
  MoolahVault public vault;

  // Market commons
  MarketParams public marketParams;
  Id public id;

  // Token handles (real tokens on fork or mocks locally if used)
  IERC20 public loanToken;
  IERC20 public collateralToken;
  OracleMock public oracle; // unused in fork path
  IrmMock public irm; // unused in fork path
  address supplier = address(0x201);
  address borrower = address(0x202);
  address liquidator = address(0x203);

  uint256 constant LTV = 0.8e18;
  uint256 constant SUPPLY_LIQ = 1_000_000 ether;
  uint256 constant COLLATERAL = 1_000 ether;

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
      abi.encodeWithSelector(Moolah.initialize.selector, ADMIN, MANAGER, PAUSER, 0)
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
    irm = new IrmMock();
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableLltv(80 * 1e16); // 80%

    // Vault (only used as supply receiver for interest in tests)
    vault = new MoolahVault(address(moolah), address(LISUSD));

    // RateCalculator proxy
    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, ADMIN, MANAGER, PAUSER, BOT)
    );
    rateCalc = RateCalculator(address(rcProxy));

    // Deploy LendingBroker proxy first (used as oracle by the market)
    LendingBroker bImpl = new LendingBroker(address(moolah), address(vault), address(oracle));
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

    // Token handles
    loanToken = IERC20(address(LISUSD));
    collateralToken = IERC20(address(BTCB));

    // Fund borrower with collateral and deposit to Moolah
    BTCB.setBalance(borrower, COLLATERAL);
    vm.startPrank(borrower);
    collateralToken.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(marketParams, COLLATERAL, borrower, bytes(""));
    vm.stopPrank();

    // Approval for borrower -> broker (for future repay)
    vm.prank(borrower);
    loanToken.approve(address(broker), type(uint256).max);
  }

  function _snapshot(address user) internal view returns (Market memory market, Position memory pos) {
    market = moolah.market(id);
    pos = moolah.position(id, user);
  }

  function _principalRepaid(Market memory beforeMarket, Market memory afterMarket) internal pure returns (uint256) {
    return uint256(beforeMarket.totalBorrowAssets) - uint256(afterMarket.totalBorrowAssets);
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
    assertEq(loanToken.balanceOf(borrower), borrowAmt);

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

    uint256 helperAfter = loanToken.balanceOf(helper);
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
    uint256 balanceBefore = loanToken.balanceOf(borrower);

    vm.prank(borrower);
    broker.repay(budget, borrower);

    uint256 balanceAfter = loanToken.balanceOf(borrower);
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

    uint256 helperAfter = loanToken.balanceOf(helper);
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
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(51, 45 days, RATE_SCALE + 2);

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
      : BrokerMath.mulDivFlooring(outstandingInterest, convertAmount, principalBefore);
    uint256 expectedNormalizedDelta = BrokerMath.normalizeBorrowAmount(convertAmount + expectedInterestShare, rate);
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
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(52, 30 days, RATE_SCALE + 1);

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
    uint256 expectedNormalizedDelta = BrokerMath.normalizeBorrowAmount(actualDebt, rate);

    vm.prank(borrower);
    broker.convertDynamicToFixed(principalBefore, 52);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertEq(principalAfter, 0, "dynamic principal should be cleared");
    assertEq(normalizedAfter, 0, "dynamic normalized debt should be cleared");

    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(borrower);
    assertEq(fixedPositions.length, 1);
    assertEq(
      fixedPositions[0].principal,
      principalBefore + outstandingInterest,
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
    uint256 apr = RATE_SCALE; // treat as 1x over the term -> zero interest growth component
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(termId, duration, apr);

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
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(21, 45 days, RATE_SCALE + 5e24);

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

    uint256 helperAfter = loanToken.balanceOf(helper);
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
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(22, 30 days, RATE_SCALE + 3);

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

    uint256 helperAfter = loanToken.balanceOf(helper);
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

  // -----------------------------
  // Liquidation path: dynamic first, then fixed (sorted by maturity)
  // -----------------------------
  function test_liquidation_updatesBrokerPositions() public {
    uint256 dynBorrow = 600 ether;
    vm.prank(borrower);
    broker.borrow(dynBorrow);

    vm.prank(MANAGER);
    broker.setFixedTermAndRate(31, 45 days, RATE_SCALE + 2);

    vm.prank(borrower);
    broker.borrow(300 ether, 31);

    FixedLoanPosition[] memory beforeFix = broker.userFixedPositions(borrower);
    assertEq(beforeFix.length, 1);
    uint256 fixedPosId = beforeFix[0].posId;

    (uint256 dynPrincipalBefore, uint256 dynNormalizedBefore) = broker.dynamicLoanPositions(borrower);

    // make the account unhealthy
    oracle.setPrice(address(BTCB), 10_000_000);

    Market memory mmkt = moolah.market(id);
    Position memory pre = moolah.position(id, borrower);
    uint256 repayAssets = 50 ether; // keep smaller than dynamic principal so fixed should remain untouched
    uint256 repaidShares = repayAssets.toSharesUp(mmkt.totalBorrowAssets, mmkt.totalBorrowShares);

    LISUSD.setBalance(liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    moolah.liquidate(marketParams, borrower, 0, repaidShares, bytes(""));
    vm.stopPrank();

    vm.prank(address(moolah));
    broker.liquidate(id, borrower);

    (uint256 dynPrincipalAfter, uint256 dynNormalizedAfter) = broker.dynamicLoanPositions(borrower);
    assertLt(dynPrincipalAfter, dynPrincipalBefore, "dynamic principal not reduced");
    assertLt(dynNormalizedAfter, dynNormalizedBefore, "normalized debt unchanged");

    FixedLoanPosition[] memory afterFix = broker.userFixedPositions(borrower);
    assertEq(afterFix.length, 1, "fixed position count should stay the same");
    FixedLoanPosition memory fixedAfter = afterFix[0];
    assertEq(fixedAfter.posId, fixedPosId);
    assertEq(
      fixedAfter.principalRepaid,
      beforeFix[0].principalRepaid,
      "fixed position should remain untouched until dynamic cleared"
    );

    Position memory post = moolah.position(id, borrower);
    assertLt(post.borrowShares, pre.borrowShares, "moolah borrow shares should fall");
  }

  function test_liquidation_prefersEarlierMaturityFixedPosition() public {
    // configure three fixed terms with increasing maturities
    vm.startPrank(MANAGER);
    broker.setFixedTermAndRate(1, 30 days, RATE_SCALE + 1);
    broker.setFixedTermAndRate(2, 60 days, RATE_SCALE + 1);
    broker.setFixedTermAndRate(3, 90 days, RATE_SCALE + 1);
    vm.stopPrank();

    // borrow against each term
    vm.startPrank(borrower);
    broker.borrow(200 ether, 1);
    broker.borrow(200 ether, 2);
    broker.borrow(200 ether, 3);
    vm.stopPrank();

    FixedLoanPosition[] memory beforeFix = broker.userFixedPositions(borrower);
    (uint256 shortPosId, uint256 midPosId, uint256 longPosId) = _classifyByDuration(beforeFix);
    assertTrue(shortPosId != 0 && midPosId != 0 && longPosId != 0, "missing fixed positions");

    // force undercollateralization
    oracle.setPrice(address(BTCB), 10_000_000);

    Market memory mmkt = moolah.market(id);
    Position memory pre = moolah.position(id, borrower);
    uint256 repayAssets = 50 ether; // less than a single principal so only first maturity should absorb it
    uint256 repaidShares = repayAssets.toSharesUp(mmkt.totalBorrowAssets, mmkt.totalBorrowShares);

    // perform liquidation at Moolah level
    LISUSD.setBalance(liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    moolah.liquidate(marketParams, borrower, 0, repaidShares, bytes(""));
    vm.stopPrank();

    // invoke broker side liquidation (restricted to Moolah)
    vm.prank(address(moolah));
    broker.liquidate(id, borrower);

    FixedLoanPosition[] memory afterFix = broker.userFixedPositions(borrower);
    FixedLoanPosition memory shortAfter;
    FixedLoanPosition memory midAfter;
    FixedLoanPosition memory longAfter;
    bool shortFound;
    bool midFound;
    bool longFound;
    (shortAfter, shortFound) = _findByPosId(afterFix, shortPosId);
    (midAfter, midFound) = _findByPosId(afterFix, midPosId);
    (longAfter, longFound) = _findByPosId(afterFix, longPosId);

    // earlier maturity should absorb repayment while later ones remain untouched
    assertTrue(shortFound, "short maturity position missing");
    assertGt(shortAfter.principalRepaid, 0, "earliest maturity not prioritized");

    if (midFound) {
      assertEq(
        midAfter.principalRepaid,
        beforeFix[_indexOf(beforeFix, midPosId)].principalRepaid,
        "mid maturity unexpectedly repaid"
      );
    }
    if (longFound) {
      assertEq(
        longAfter.principalRepaid,
        beforeFix[_indexOf(beforeFix, longPosId)].principalRepaid,
        "long maturity unexpectedly repaid"
      );
    }

    Position memory post = moolah.position(id, borrower);
    assertLt(post.borrowShares, pre.borrowShares, "moolah shares not reduced");
  }

  function test_liquidation_dynamicInterestOnlyLeavesPrincipalIntact() public {
    uint256 borrowAmt = 800 ether;
    vm.prank(borrower);
    broker.borrow(borrowAmt);

    vm.prank(BOT);
    rateCalc.setRatePerSecond(address(broker), RATE_SCALE + 2);

    skip(200 days);

    oracle.setPrice(address(BTCB), 10_000_000);

    (uint256 principalBefore, uint256 normalizedBefore) = broker.dynamicLoanPositions(borrower);
    uint256 rate = IRateCalculator(address(rateCalc)).accrueRate(address(broker));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(normalizedBefore, rate);
    uint256 interestOutstanding = actualDebt > principalBefore ? actualDebt - principalBefore : 0;
    assertGt(interestOutstanding, 0, "no accrued interest");

    Market memory marketBefore = moolah.market(id);
    uint256 repaidShares = interestOutstanding.toSharesDown(
      marketBefore.totalBorrowAssets,
      marketBefore.totalBorrowShares
    );
    if (repaidShares == 0) {
      repaidShares = interestOutstanding.toSharesUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
    }
    assertGt(repaidShares, 0, "repaid shares zero");

    uint256 assumedAssets = repaidShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
    assertLe(assumedAssets, interestOutstanding + 1 ether, "liquidation tries to repay principal portion");

    address liquidator2 = address(0xABC);
    uint256 startingBalance = assumedAssets + 1 ether;
    LISUSD.setBalance(liquidator2, startingBalance);
    vm.startPrank(liquidator2);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    moolah.liquidate(marketParams, borrower, 0, repaidShares, bytes(""));
    vm.stopPrank();

    vm.prank(address(moolah));
    broker.liquidate(id, borrower);

    (uint256 principalAfter, uint256 normalizedAfter) = broker.dynamicLoanPositions(borrower);
    uint256 balanceAfter = loanToken.balanceOf(liquidator2);
    uint256 spentAssets = startingBalance - balanceAfter;
    assertGt(spentAssets, 0, "no assets spent");

    uint256 tolerance = 1e9; // allow for rounding noise
    if (spentAssets <= interestOutstanding + tolerance) {
      assertEq(principalAfter, principalBefore, "principal should remain when only interest is repaid");
    } else {
      uint256 principalPaid = spentAssets - interestOutstanding;
      uint256 actualPrincipalPaid = principalBefore - principalAfter;
      assertApproxEqAbs(actualPrincipalPaid, principalPaid, tolerance, "principal repayment mismatch");
    }

    uint256 principalDrop = principalBefore - principalAfter;
    assertLe(principalDrop, spentAssets + tolerance, "principal decreased more than assets repaid");
    assertLe(normalizedAfter, normalizedBefore, "normalized debt increased");
  }

  function _classifyByDuration(
    FixedLoanPosition[] memory positions
  ) internal pure returns (uint256 shortPosId, uint256 midPosId, uint256 longPosId) {
    for (uint256 i = 0; i < positions.length; i++) {
      uint256 duration = positions[i].end - positions[i].start;
      if (duration == 30 days) {
        shortPosId = positions[i].posId;
      } else if (duration == 60 days) {
        midPosId = positions[i].posId;
      } else if (duration == 90 days) {
        longPosId = positions[i].posId;
      }
    }
  }

  function _findByPosId(
    FixedLoanPosition[] memory positions,
    uint256 posId
  ) internal pure returns (FixedLoanPosition memory position, bool found) {
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        return (positions[i], true);
      }
    }
    return (position, false);
  }

  function _indexOf(FixedLoanPosition[] memory positions, uint256 posId) internal pure returns (uint256) {
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        return i;
      }
    }
    revert("position not found");
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

  function test_setFixedTermOnlyManager_Reverts() public {
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    vm.prank(borrower);
    broker.setFixedTermAndRate(42, 30 days, RATE_SCALE);
  }

  function test_setMaxFixedLoanPositions_Enforced() public {
    vm.startPrank(MANAGER);
    broker.setMaxFixedLoanPositions(1);
    broker.setFixedTermAndRate(11, 60 days, RATE_SCALE);
    vm.stopPrank();

    vm.startPrank(borrower);
    broker.borrow(1 ether, 11);
    vm.expectRevert(bytes("broker/exceed-max-fixed-positions"));
    broker.borrow(1 ether, 11);
    vm.stopPrank();
  }

  function test_liquidateOnlyMoolah_Reverts() public {
    vm.expectRevert(bytes("Broker/not-moolah"));
    broker.liquidate(id, borrower);
  }

  function test_peekLoanToken_OneE8() public {
    uint256 p = broker.peek(address(LISUSD), borrower);
    assertEq(p, 1e8);
  }

  function test_peekCollateralReducedWithFixedInterest() public {
    // Set a fixed term, borrow fixed, wait, then check price reduces
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(77, 30 days, RATE_SCALE + 5e24);
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
    vm.expectRevert(bytes("Broker/unsupported-token"));
    broker.peek(address(0xDEAD), borrower);
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
    // termId = 0
    vm.expectRevert(bytes("broker/invalid-term-id"));
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(0, 1 days, RATE_SCALE);
    // duration = 0
    vm.expectRevert(bytes("broker/invalid-duration"));
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(1, 0, RATE_SCALE);
    // apr < RATE_SCALE
    vm.expectRevert(bytes("broker/invalid-apr"));
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(1, 1 days, RATE_SCALE - 1);
  }

  function test_removeFixedTerm_success_and_notFound_revert() public {
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(3, 10 days, RATE_SCALE);
    // ensure added
    FixedTermAndRate[] memory terms = broker.getFixedTerms();
    assertEq(terms.length, 1);
    assertEq(terms[0].termId, 3);
    // remove
    vm.prank(MANAGER);
    broker.removeFixedTermAndRate(3);
    terms = broker.getFixedTerms();
    assertEq(terms.length, 0);
    // remove again -> revert
    vm.expectRevert(bytes("broker/term-not-found"));
    vm.prank(MANAGER);
    broker.removeFixedTermAndRate(3);
  }

  function test_getFixedTerms_update_inPlace() public {
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(5, 7 days, RATE_SCALE);
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(5, 14 days, RATE_SCALE + 1);
    FixedTermAndRate[] memory terms = broker.getFixedTerms();
    assertEq(terms.length, 1);
    assertEq(terms[0].termId, 5);
    assertEq(terms[0].duration, 14 days);
    assertEq(terms[0].apr, RATE_SCALE + 1);
  }

  function test_refinance_matured_success() public {
    // create a short-term fixed position
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(100, 1 hours, RATE_SCALE);
    vm.prank(borrower);
    broker.borrow(500 ether, 100);
    // let it mature
    skip(2 hours);
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    uint256 posId = positions[0].posId;
    // refinance as BOT
    uint256[] memory posIds = new uint256[](1);
    posIds[0] = posId;
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

  function test_liquidate_invalidMarket_reverts() public {
    // construct a bogus id with different token pair
    MarketParams memory bogus = MarketParams({
      loanToken: address(0x1),
      collateralToken: address(0x2),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 80 * 1e16
    });
    Id badId = bogus.id();
    vm.expectRevert(bytes("Broker/invalid-market"));
    vm.prank(address(moolah));
    broker.liquidate(badId, borrower);
  }

  function test_setMaxFixedLoanPositions_sameValue_reverts() public {
    // default is 10 (from initialize)
    vm.expectRevert(bytes("broker/same-value-provided"));
    vm.prank(MANAGER);
    broker.setMaxFixedLoanPositions(10);
  }
}

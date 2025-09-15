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
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10
      )
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
    moolah.supply(marketParams, seed, 0, supplier, bytes("") );
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
    broker.repay(repayAmt);

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

    // Partial repay: ensure amount > interest + penalty
    uint256 partialRepay = 100 ether;
    vm.prank(borrower);
    broker.repay(partialRepay, posId);

    // Position should still exist with reduced remaining principal
    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    assertLt(positions[0].repaidPrincipal, positions[0].principal);

    // Full repay remaining
    // Top up borrower to ensure enough balance, then overpay to cover any interest/penalty
    LISUSD.setBalance(borrower, 1000 ether);
    uint256 repayAll = 1000 ether;
    vm.prank(borrower);
    broker.repay(repayAll, posId);

    // Position fully removed
    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
  }

  // -----------------------------
  // Liquidation path: dynamic first, then fixed (sorted)
  // -----------------------------
  function test_liquidation_updatesBrokerPositions() public {
    // Prepare positions
    uint256 dynBorrow = 600 ether;
    vm.prank(borrower);
    broker.borrow(dynBorrow);

    // Two fixed terms with different APRs
    vm.startPrank(MANAGER);
    broker.setFixedTermAndRate(1, 60 days, RATE_SCALE + 5e24); // lower APR
    broker.setFixedTermAndRate(2, 60 days, RATE_SCALE + 1e25); // higher APR
    vm.stopPrank();

    vm.startPrank(borrower);
    broker.borrow(300 ether, 1); // lower APR
    broker.borrow(400 ether, 2); // higher APR
    vm.stopPrank();

    // Partially repay one fixed position to create different remaining principals
    FixedLoanPosition[] memory beforeFix = broker.userFixedPositions(borrower);
    uint256 lowAprPosId = beforeFix[0].apr < beforeFix[1].apr ? beforeFix[0].posId : beforeFix[1].posId;
    vm.prank(borrower);
    broker.repay(50 ether, lowAprPosId); // small partial repay

    // Make position unhealthy by dropping collateral price via OracleMock
    oracle.setPrice(address(BTCB), 10_000_000); // ~$0.10 to force undercollateralization but keep > 0

    // Compute a safe repaidShares amount from a small repayAssets to avoid over-seizing collateral
    Market memory mmkt = moolah.market(id);
    Position memory pre = moolah.position(id, borrower);
    uint256 repayAssets = 10 ether;
    uint256 repaidShares = repayAssets.toSharesUp(mmkt.totalBorrowAssets, mmkt.totalBorrowShares);

    // Fund and approve liquidator for repay
    LISUSD.setBalance(liquidator, 1_000 ether);
    vm.startPrank(liquidator);
    IERC20(address(LISUSD)).approve(address(moolah), type(uint256).max);
    // Liquidate in Moolah (repay shares option)
    moolah.liquidate(marketParams, borrower, 0, repaidShares, bytes(""));
    vm.stopPrank();

    // Simulate Moolah calling broker.liquidate (onlyMoolah)
    vm.prank(address(moolah));
    broker.liquidate(id, borrower);

    // After liquidation, dynamic principal should reduce (maybe to zero)
    (uint256 dynPrincipalAfter, ) = broker.dynamicLoanPositions(borrower);

    // Higher APR fixed position should be favored in deduction
    FixedLoanPosition[] memory afterFix = broker.userFixedPositions(borrower);
    // If any fixed positions remain, ensure at least one had principal reduced
    if (afterFix.length > 0) {
      bool anyReduced = false;
      for (uint256 i = 0; i < afterFix.length; i++) {
        // fetch original matching pos
        for (uint256 j = 0; j < beforeFix.length; j++) {
          if (afterFix[i].posId == beforeFix[j].posId && afterFix[i].repaidPrincipal > beforeFix[j].repaidPrincipal) {
            anyReduced = true;
          }
        }
      }
      assertTrue(anyReduced, "no fixed principal reduction");
    }

    // Moolah shares reduced
    Position memory post = moolah.position(id, borrower);
    assertLt(post.borrowShares, pre.borrowShares);

    // Dynamic principal may be zero or smaller after liquidation
    assertLe(dynPrincipalAfter, dynBorrow);
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
    broker.setFixedTermAndRate(77, 30 days, RATE_SCALE);
    // initial price from oracle
    uint256 p0 = broker.peek(address(BTCB), borrower);
    vm.prank(borrower);
    broker.borrow(100 ether, 77);
    skip(1 days);
    uint256 p1 = broker.peek(address(BTCB), borrower);
    assertLt(p1, p0, "collateral price did not decrease");
  }

  function test_fixedRepay_Insufficient_Reverts() public {
    // Create a fixed position
    vm.prank(MANAGER);
    broker.setFixedTermAndRate(88, 30 days, RATE_SCALE);
    vm.prank(borrower);
    broker.borrow(200 ether, 88);
    // accrue some interest
    skip(1 days);
    // repay too little (<= interest), should revert
    vm.expectRevert(bytes("broker/repay-amount-insufficient"));
    vm.prank(borrower);
    broker.repay(1, 1); // posId is 1 for the first fixed position
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
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10
      )
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

  function test_dynamicRepay_insufficient_interest_reverts() public {
    vm.prank(borrower);
    broker.borrow(1000 ether);
    // accrue some interest to make accruedInterest > 0
    skip(1 days);
    vm.expectRevert(bytes("broker/repay-amount-insufficient"));
    vm.prank(borrower);
    broker.repay(1);
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

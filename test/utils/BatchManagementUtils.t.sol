// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMockZero } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";
import { FixedTermAndRate, FixedLoanPosition, DynamicLoanPosition } from "../../src/broker/interfaces/IBroker.sol";
import { RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";

import { BatchManagementUtils } from "../../src/utils/BatchManagementUtils.sol";

contract BatchManagementUtilsTest is Test {
  using MarketParamsLib for MarketParams;

  // ---- Core ----
  IMoolah public moolah;
  RateCalculator public rateCalc;
  BatchManagementUtils public batch;

  // ---- Brokers (one per market) ----
  LendingBroker public broker1;
  LendingBroker public broker2;
  MarketParams public market1Params;
  MarketParams public market2Params;
  Id public id1;
  Id public id2;

  // ---- Tokens / oracle / irm ----
  ERC20Mock public LOAN;
  ERC20Mock public COL;
  OracleMock public oracle;
  IrmMockZero public irm;

  // ---- Roles ----
  address constant ADMIN = address(0xA0);
  address constant MANAGER = address(0xA1);
  address constant PAUSER = address(0xA2);
  address constant BOT = address(0xA3);
  address constant RELAYER_STUB = address(0xBEEF); // unused in tests; immutable can't be zero

  // ---- Test actors ----
  address supplier = address(0x201);
  address borrower = address(0x202);

  uint256 constant LTV = 80 * 1e16; // 80%
  uint256 constant SUPPLY_LIQ = 1_000_000 ether;
  uint256 constant COLLATERAL = 1 ether;

  bytes32 internal constant BOT_ROLE = keccak256("BOT");

  function setUp() public {
    // --- Moolah ---
    Moolah mImpl = new Moolah();
    ERC1967Proxy mProxy = new ERC1967Proxy(
      address(mImpl),
      abi.encodeWithSelector(Moolah.initialize.selector, ADMIN, MANAGER, PAUSER, 15e8)
    );
    moolah = IMoolah(address(mProxy));

    // --- Tokens + oracle + irm ---
    LOAN = new ERC20Mock();
    LOAN.setName("Lista USD");
    LOAN.setSymbol("LISUSD");
    LOAN.setDecimals(18);
    COL = new ERC20Mock();
    COL.setName("Collateral");
    COL.setSymbol("COL");
    COL.setDecimals(18);
    oracle = new OracleMock();
    oracle.setPrice(address(LOAN), 1e8);
    oracle.setPrice(address(COL), 120000e8);
    irm = new IrmMockZero();
    vm.startPrank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    Moolah(address(moolah)).enableLltv(LTV);
    vm.stopPrank();

    // --- RateCalculator ---
    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, ADMIN, MANAGER, BOT)
    );
    rateCalc = RateCalculator(address(rcProxy));

    // --- Brokers ---
    broker1 = _deployBroker();
    broker2 = _deployBroker();

    // --- Markets (broker is the oracle) ---
    market1Params = MarketParams({
      loanToken: address(LOAN),
      collateralToken: address(COL),
      oracle: address(broker1),
      irm: address(irm),
      lltv: LTV
    });
    id1 = market1Params.id();
    Moolah(address(moolah)).createMarket(market1Params);

    market2Params = MarketParams({
      loanToken: address(LOAN),
      collateralToken: address(COL),
      oracle: address(broker2),
      irm: address(irm),
      lltv: LTV
    });
    id2 = market2Params.id();
    Moolah(address(moolah)).createMarket(market2Params);

    // --- Bind brokers to markets & register ---
    vm.startPrank(MANAGER);
    broker1.setMarketId(id1);
    broker2.setMarketId(id2);
    rateCalc.registerBroker(address(broker1), RATE_SCALE + 1, RATE_SCALE + 2);
    rateCalc.registerBroker(address(broker2), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(id1, address(broker1), true);
    Moolah(address(moolah)).setMarketBroker(id2, address(broker2), true);
    vm.stopPrank();

    // --- Liquidity & borrower collateral on both markets ---
    LOAN.setBalance(supplier, SUPPLY_LIQ * 2);
    vm.startPrank(supplier);
    IERC20(address(LOAN)).approve(address(moolah), type(uint256).max);
    moolah.supply(market1Params, SUPPLY_LIQ, 0, supplier, bytes(""));
    moolah.supply(market2Params, SUPPLY_LIQ, 0, supplier, bytes(""));
    vm.stopPrank();

    COL.setBalance(borrower, COLLATERAL * 4);
    vm.startPrank(borrower);
    COL.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(market1Params, COLLATERAL, borrower, bytes(""));
    moolah.supplyCollateral(market2Params, COLLATERAL, borrower, bytes(""));
    vm.stopPrank();

    // --- Deploy BatchManagementUtils ---
    BatchManagementUtils batchImpl = new BatchManagementUtils(address(moolah));
    ERC1967Proxy batchProxy = new ERC1967Proxy(
      address(batchImpl),
      abi.encodeWithSelector(BatchManagementUtils.initialize.selector, ADMIN, MANAGER)
    );
    batch = BatchManagementUtils(address(batchProxy));

    // --- Grant BOT role on each broker to the utility (so it can forward the call) ---
    vm.startPrank(ADMIN);
    IAccessControl(address(broker1)).grantRole(BOT_ROLE, address(batch));
    IAccessControl(address(broker2)).grantRole(BOT_ROLE, address(batch));
    vm.stopPrank();
  }

  function _deployBroker() internal returns (LendingBroker b) {
    LendingBroker impl = new LendingBroker(address(moolah), address(0));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        PAUSER,
        address(rateCalc),
        10,
        RELAYER_STUB,
        address(oracle)
      )
    );
    b = LendingBroker(payable(address(proxy)));
  }

  /// @dev Deploy a broker, create a fresh market with it as oracle, bind, and register as the market's canonical broker.
  uint256 internal _brokerMarketSeed;

  function _deployAndRegisterBroker() internal returns (LendingBroker b) {
    b = _deployBroker();
    // unique LLTV per registered broker to avoid Id collisions across calls
    uint256 lltv = LTV - (++_brokerMarketSeed) * 1e14;
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableLltv(lltv);
    MarketParams memory mp = MarketParams({
      loanToken: address(LOAN),
      collateralToken: address(COL),
      oracle: address(b),
      irm: address(irm),
      lltv: lltv
    });
    Id mid = mp.id();
    Moolah(address(moolah)).createMarket(mp);
    vm.startPrank(MANAGER);
    b.setMarketId(mid);
    rateCalc.registerBroker(address(b), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(mid, address(b), true);
    vm.stopPrank();
  }

  // -------------------------------------------------------------------
  //                  batchUpdateFixedTermAndRate
  // -------------------------------------------------------------------

  function test_batchUpdateFixedTermAndRate_addsTermsAcrossBrokers() public {
    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1);
    brokers[1] = address(broker2);

    FixedTermAndRate[] memory terms = new FixedTermAndRate[](2);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 }); // 5% APR
    terms[1] = FixedTermAndRate({ termId: 2, duration: 90 days, apr: 110 * 1e25 }); // 10% APR

    bool[] memory removes = new bool[](2);

    vm.prank(BOT);
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);

    FixedTermAndRate[] memory got1 = broker1.getFixedTerms();
    FixedTermAndRate[] memory got2 = broker2.getFixedTerms();
    assertEq(got1.length, 1, "broker1 term count");
    assertEq(got1[0].termId, 1);
    assertEq(got1[0].duration, 30 days);
    assertEq(got1[0].apr, 105 * 1e25);
    assertEq(got2.length, 1, "broker2 term count");
    assertEq(got2[0].termId, 2);
    assertEq(got2[0].duration, 90 days);
    assertEq(got2[0].apr, 110 * 1e25);
  }

  function test_batchUpdateFixedTermAndRate_updateAndRemove() public {
    // seed an existing term on broker1
    vm.prank(BOT);
    broker1.updateFixedTermAndRate(FixedTermAndRate({ termId: 7, duration: 30 days, apr: 105 * 1e25 }), false);

    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1); // update existing
    brokers[1] = address(broker1); // remove it

    FixedTermAndRate[] memory terms = new FixedTermAndRate[](2);
    terms[0] = FixedTermAndRate({ termId: 7, duration: 45 days, apr: 108 * 1e25 });
    terms[1] = FixedTermAndRate({ termId: 7, duration: 1, apr: 105 * 1e25 }); // payload ignored on remove

    bool[] memory removes = new bool[](2);
    removes[0] = false;
    removes[1] = true;

    vm.prank(BOT);
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);

    assertEq(broker1.getFixedTerms().length, 0, "term should be removed");
  }

  function test_batchUpdateFixedTermAndRate_callerWithoutBot_reverts() public {
    address[] memory brokers = new address[](1);
    brokers[0] = address(broker1);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](1);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 });
    bool[] memory removes = new bool[](1);

    vm.expectRevert(bytes("Not bot of broker"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  function test_batchUpdateFixedTermAndRate_callerHasBotOnSomeNotAll_reverts() public {
    // BOT holds the role on broker1 (from initialize) but we'll strip it on broker3
    LendingBroker broker3 = _deployAndRegisterBroker();

    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1);
    brokers[1] = address(broker3);

    FixedTermAndRate[] memory terms = new FixedTermAndRate[](2);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 });
    terms[1] = FixedTermAndRate({ termId: 2, duration: 30 days, apr: 105 * 1e25 });
    bool[] memory removes = new bool[](2);

    // revoke BOT on broker3 so it differs from broker1
    vm.prank(ADMIN);
    IAccessControl(address(broker3)).revokeRole(BOT_ROLE, BOT);

    vm.prank(BOT);
    vm.expectRevert(bytes("Not bot of broker"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);

    // and broker1 should not have been mutated (whole tx reverted)
    assertEq(broker1.getFixedTerms().length, 0);
  }

  function test_batchUpdateFixedTermAndRate_unregisteredBroker_reverts() public {
    // freshly deployed broker, never bound to a market or registered in Moolah
    LendingBroker rogue = _deployBroker();

    address[] memory brokers = new address[](1);
    brokers[0] = address(rogue);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](1);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 });
    bool[] memory removes = new bool[](1);

    vm.prank(BOT);
    vm.expectRevert(bytes("Invalid broker"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  function test_batchUpdateFixedTermAndRate_maliciousBroker_reverts() public {
    // attacker contract that faks MARKET_ID() to broker1's market and hasRole() to true
    MaliciousBroker rogue = new MaliciousBroker(broker1.MARKET_ID());

    address[] memory brokers = new address[](1);
    brokers[0] = address(rogue);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](1);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 });
    bool[] memory removes = new bool[](1);

    // moolah.brokers(broker1's id) == broker1, not rogue ⇒ revert before role check or dispatch
    vm.expectRevert(bytes("Invalid broker"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  function test_batchUpdateFixedTermAndRate_lengthMismatch_reverts() public {
    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1);
    brokers[1] = address(broker2);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](1);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 105 * 1e25 });
    bool[] memory removes = new bool[](2);

    vm.prank(BOT);
    vm.expectRevert(bytes("Array length mismatch"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  function test_batchUpdateFixedTermAndRate_empty_reverts() public {
    address[] memory brokers = new address[](0);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](0);
    bool[] memory removes = new bool[](0);

    vm.prank(BOT);
    vm.expectRevert(bytes("Array length mismatch"));
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  function test_batchUpdateFixedTermAndRate_brokerLevelValidation_reverts() public {
    // apr below MIN_FIXED_TERM_APR (1e27) should bubble up
    address[] memory brokers = new address[](1);
    brokers[0] = address(broker1);
    FixedTermAndRate[] memory terms = new FixedTermAndRate[](1);
    terms[0] = FixedTermAndRate({ termId: 1, duration: 30 days, apr: 1e25 }); // way below min
    bool[] memory removes = new bool[](1);

    vm.prank(BOT);
    vm.expectRevert(LendingBroker.InvalidAPR.selector);
    batch.batchUpdateFixedTermAndRate(brokers, terms, removes);
  }

  // -------------------------------------------------------------------
  //                         batchRefinance
  // -------------------------------------------------------------------

  function _seedMaturedFixedPosition(LendingBroker b, uint256 termId, uint256 amount) internal returns (uint256 posId) {
    vm.prank(BOT);
    b.updateFixedTermAndRate(FixedTermAndRate({ termId: termId, duration: 1 hours, apr: 105 * 1e25 }), false);

    vm.prank(borrower);
    b.borrow(amount, termId);

    FixedLoanPosition[] memory positions = b.userFixedPositions(borrower);
    posId = positions[positions.length - 1].posId;
  }

  function test_batchRefinance_acrossBrokers_movesPositionsToDynamic() public {
    uint256 pos1 = _seedMaturedFixedPosition(broker1, 100, 500 ether);
    uint256 pos2 = _seedMaturedFixedPosition(broker2, 100, 300 ether);
    skip(2 hours);

    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1);
    brokers[1] = address(broker2);
    address[] memory users = new address[](2);
    users[0] = borrower;
    users[1] = borrower;
    uint256[][] memory posIds = new uint256[][](2);
    posIds[0] = new uint256[](1);
    posIds[0][0] = pos1;
    posIds[1] = new uint256[](1);
    posIds[1][0] = pos2;

    vm.prank(BOT);
    batch.batchRefinance(brokers, users, posIds);

    assertEq(broker1.userFixedPositions(borrower).length, 0, "broker1 fixed cleared");
    assertEq(broker2.userFixedPositions(borrower).length, 0, "broker2 fixed cleared");
    (uint256 p1, ) = broker1.dynamicLoanPositions(borrower);
    (uint256 p2, ) = broker2.dynamicLoanPositions(borrower);
    assertEq(p1, 500 ether, "broker1 dynamic principal");
    assertEq(p2, 300 ether, "broker2 dynamic principal");
  }

  function test_batchRefinance_callerWithoutBot_reverts() public {
    address[] memory brokers = new address[](1);
    brokers[0] = address(broker1);
    address[] memory users = new address[](1);
    users[0] = borrower;
    uint256[][] memory posIds = new uint256[][](1);
    posIds[0] = new uint256[](1);
    posIds[0][0] = 0;

    vm.expectRevert(bytes("Not bot of broker"));
    batch.batchRefinance(brokers, users, posIds);
  }

  function test_batchRefinance_lengthMismatch_reverts() public {
    address[] memory brokers = new address[](2);
    brokers[0] = address(broker1);
    brokers[1] = address(broker2);
    address[] memory users = new address[](1);
    users[0] = borrower;
    uint256[][] memory posIds = new uint256[][](2);
    posIds[0] = new uint256[](0);
    posIds[1] = new uint256[](0);

    vm.prank(BOT);
    vm.expectRevert(bytes("Array length mismatch"));
    batch.batchRefinance(brokers, users, posIds);
  }

  function test_batchRefinance_empty_reverts() public {
    address[] memory brokers = new address[](0);
    address[] memory users = new address[](0);
    uint256[][] memory posIds = new uint256[][](0);

    vm.prank(BOT);
    vm.expectRevert(bytes("Array length mismatch"));
    batch.batchRefinance(brokers, users, posIds);
  }

  function test_batchRefinance_unmaturedPosition_bubblesBrokerRevert() public {
    uint256 pos1 = _seedMaturedFixedPosition(broker1, 100, 500 ether);
    // do NOT skip past maturity

    address[] memory brokers = new address[](1);
    brokers[0] = address(broker1);
    address[] memory users = new address[](1);
    users[0] = borrower;
    uint256[][] memory posIds = new uint256[][](1);
    posIds[0] = new uint256[](1);
    posIds[0][0] = pos1;

    vm.prank(BOT);
    vm.expectRevert(bytes("Broker/position-not-expired"));
    batch.batchRefinance(brokers, users, posIds);
  }
}

/// @dev Pretends to be a LendingBroker: returns a chosen MARKET_ID and reports hasRole=true for anyone.
contract MaliciousBroker {
  Id public MARKET_ID;

  constructor(Id _marketId) {
    MARKET_ID = _marketId;
  }

  function hasRole(bytes32, address) external pure returns (bool) {
    return true;
  }
}

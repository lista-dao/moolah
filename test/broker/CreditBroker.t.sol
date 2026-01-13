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

import { CreditBroker } from "../../src/broker/CreditBroker.sol";
import { CreditBrokerInterestRelayer } from "../../src/broker/CreditBrokerInterestRelayer.sol";
import { ICreditBroker, FixedLoanPosition, FixedTermAndRate, GraceConfig, FixedTermType } from "../../src/broker/interfaces/ICreditBroker.sol";
import { CreditBrokerMath, RATE_SCALE } from "../../src/broker/libraries/CreditBrokerMath.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketAllocation } from "../../src/moolah-vault/interfaces/IMoolahVault.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { ORACLE_PRICE_SCALE, LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR } from "moolah/libraries/ConstantsLib.sol";

import { CreditToken } from "../../src/utils/CreditToken.sol";
import { Merkle } from "murky/src/Merkle.sol";

contract CreditBrokerTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;
  using UtilsLib for uint256;

  // ========= Shared state (unused fields may remain default in some tests) =========
  // Core
  IMoolah public moolah;
  CreditBroker public broker;
  MoolahVault public vault;
  CreditBrokerInterestRelayer public relayer;

  // Market commons
  MarketParams public marketParams;
  Id public id;

  // Token handles (real tokens on fork or mocks locally if used)
  OracleMock public oracle; // unused in fork path
  IrmMockZero public irm; // unused in fork path
  address supplier = address(0x201);
  address borrower = address(0x202);

  uint256 constant LTV = 1e18; // 100%
  uint256 constant SUPPLY_LIQ = 10_000 ether;
  uint256 constant COLLATERAL = 1_000 ether;

  // Local roles for tests
  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MANAGER = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;
  address constant PAUSER = address(0xA11A51);
  address constant BOT = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  // Local mocks
  ERC20Mock public USDT;
  uint8 constant USDT_DECIMALS = 18;

  CreditToken public creditToken;
  bytes32 merkleRoot;
  bytes32[] proof;
  Merkle m = new Merkle();

  // Mock LISTA
  ERC20Mock public LISTA;

  FixedTermType type1 = FixedTermType.ACCRUE_INTEREST;

  // setUp now forks mainnet Moolah, deploys new CreditBroker,
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
    USDT = new ERC20Mock();
    USDT.setName("Lista USD");
    USDT.setSymbol("USDT");
    USDT.setDecimals(USDT_DECIMALS);
    LISTA = new ERC20Mock();
    USDT.setName("LISTA");
    USDT.setSymbol("LISTA");
    USDT.setDecimals(USDT_DECIMALS);

    // Deploy CreditToken as collateral token
    _deployCreditToken();

    // Oracle with initial prices
    oracle = new OracleMock();
    oracle.setPrice(address(USDT), 1e8);

    // IRM enable + LLTV
    irm = new IrmMockZero();
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableIrm(address(irm));
    vm.prank(MANAGER);
    Moolah(address(moolah)).enableLltv(LTV);

    // Vault (only used as supply receiver for interest in tests)
    vault = new MoolahVault(address(moolah), address(USDT));

    // CreditBrokerInterestRelayer
    CreditBrokerInterestRelayer relayerImpl = new CreditBrokerInterestRelayer();
    ERC1967Proxy relayerProxy = new ERC1967Proxy(
      address(relayerImpl),
      abi.encodeWithSelector(
        CreditBrokerInterestRelayer.initialize.selector,
        ADMIN,
        MANAGER,
        address(moolah),
        address(vault),
        address(USDT)
      )
    );
    relayer = CreditBrokerInterestRelayer(address(relayerProxy));

    // Deploy CreditBroker proxy first (used as oracle by the market)
    CreditBroker bImpl = new CreditBroker(address(moolah), address(relayer), address(oracle), address(LISTA));
    ERC1967Proxy bProxy = new ERC1967Proxy(
      address(bImpl),
      abi.encodeWithSelector(CreditBroker.initialize.selector, ADMIN, MANAGER, BOT, PAUSER, 10)
    );
    broker = CreditBroker(payable(address(bProxy)));

    // Create market using CreditBroker as the oracle address
    marketParams = MarketParams({
      loanToken: address(USDT),
      collateralToken: address(creditToken),
      oracle: address(broker),
      irm: address(irm),
      lltv: LTV // 100%
    });
    id = marketParams.id();
    Moolah(address(moolah)).createMarket(marketParams);

    // Bind broker to market id
    vm.prank(MANAGER);
    broker.setMarketId(id);

    // Register broker and set as market broker (for user-aware pricing)
    vm.startPrank(MANAGER);
    Moolah(address(moolah)).setMarketBroker(id, address(broker), true);
    vm.stopPrank();

    // Seed market liquidity
    uint256 seed = SUPPLY_LIQ;
    USDT.setBalance(supplier, seed);
    vm.startPrank(supplier);
    IERC20(address(USDT)).approve(address(moolah), type(uint256).max);
    moolah.supply(marketParams, seed, 0, supplier, bytes(""));
    vm.stopPrank();

    // add broker into credit token
    vm.startPrank(MANAGER);
    creditToken.grantRole(creditToken.TRANSFERER(), address(broker));
    creditToken.grantRole(creditToken.TRANSFERER(), address(moolah));
    vm.stopPrank();

    // Approval for borrower -> broker (for future repay)
    vm.prank(borrower);
    USDT.approve(address(broker), type(uint256).max);

    // add broker into relayer
    vm.prank(MANAGER);
    relayer.addBroker(address(broker));

    // grace config
    (uint period, uint penaltyRate) = broker.graceConfig();
    assertEq(period, 3 days);
    assertEq(penaltyRate, 15 * 1e25);
  }

  function _deployCreditToken() public {
    CreditToken ctImpl = new CreditToken();
    ERC1967Proxy ctProxy = new ERC1967Proxy(
      address(ctImpl),
      abi.encodeWithSelector(
        CreditToken.initialize.selector,
        ADMIN,
        MANAGER,
        BOT,
        new address[](0),
        "Credit Token",
        "CRDT"
      )
    );
    creditToken = CreditToken(address(ctProxy));
  }

  function _generateTree(address _account, uint256 _score, uint256 _versionId) public {
    bytes32[] memory data = new bytes32[](4);
    data[0] = keccak256(abi.encode(block.chainid, address(creditToken), _account, _score, _versionId));
    data[1] = bytes32("0x1");
    data[2] = bytes32("0x2");
    data[3] = bytes32("0x3");
    // Get Root, Proof, and Verify
    bytes32 root = m.getRoot(data);
    bytes32[] memory _proof = m.getProof(data, 0); // will get proof for user1
    bool verified = m.verifyProof(root, _proof, data[0]);
    require(verified, "Merkle Proof not verified");

    merkleRoot = root;
    proof = _proof;

    vm.prank(BOT);
    creditToken.setPendingMerkleRoot(merkleRoot);

    vm.warp(block.timestamp + 1 days + 1);

    vm.prank(BOT);
    creditToken.acceptMerkleRoot();
  }

  function _snapshot(address user) internal view returns (Market memory market, Position memory pos) {
    market = moolah.market(id);
    pos = moolah.position(id, user);
  }

  function _principalRepaid(Market memory beforeMarket, Market memory afterMarket) internal pure returns (uint256) {
    return uint256(beforeMarket.totalBorrowAssets) - uint256(afterMarket.totalBorrowAssets);
  }

  function _totalPrincipalAtBroker(address user) internal view returns (uint256 totalPrincipal) {
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
        CreditBrokerMath.getAccruedInterestForFixedPosition(fixedPositions[i])
      );
    }
  }

  function _totalInterestAtBroker(address user) internal view returns (uint256 totalInterest) {
    FixedLoanPosition[] memory fixedPositions = broker.userFixedPositions(user);
    uint256 totalDebt;
    // total debt from fixed position
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      // add principal
      totalDebt += _fixedPos.principal - _fixedPos.principalRepaid;
      // add interest
      totalDebt += CreditBrokerMath.getAccruedInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }

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

  // -----------------------------
  // Supply and withdraw collateral
  // -----------------------------

  // Initial supply 1K collateral
  function test_supplyCollateral() public {
    // add credit broker as provider to moolah
    vm.prank(MANAGER);
    moolah.setProvider(id, address(broker), true);

    assertEq(creditToken.balanceOf(borrower), 0, "initial borrower collateral balance mismatch");
    uint256 beforeBalanceMoolah = creditToken.balanceOf(address(moolah));
    Position memory pos = moolah.position(marketParams.id(), borrower);
    assertEq(pos.collateral, 0, "moolah position collateral mismatch");

    // Fund borrower with collateral and deposit to Moolah
    _generateTree(borrower, COLLATERAL, creditToken.versionId() + 1);
    vm.startPrank(borrower);
    creditToken.approve(address(broker), type(uint256).max);
    broker.supplyCollateral(marketParams, COLLATERAL, COLLATERAL, proof);
    vm.stopPrank();

    // Check balance
    assertEq(creditToken.balanceOf(borrower), 0, "post-supply borrower collateral balance mismatch");
    assertEq(creditToken.totalSupply(), COLLATERAL, "total supply mismatch");
    assertEq(
      creditToken.balanceOf(address(moolah)) - beforeBalanceMoolah,
      COLLATERAL,
      "moolah collateral increase mismatch"
    );

    // Check broker state
    assertEq(broker.fixedPosUuid(), 0);
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);

    // Check position at Moolah
    pos = moolah.position(marketParams.id(), borrower);
    assertEq(pos.collateral, COLLATERAL, "moolah position collateral mismatch");
  }

  function test_doubleSupplyShouldRevert() public {
    test_supplyCollateral();

    assertEq(creditToken.balanceOf(borrower), 0);

    vm.expectRevert("broker/insufficient-credit-balance");
    vm.prank(borrower);
    broker.supplyCollateral(marketParams, COLLATERAL, COLLATERAL, proof);

    // Check broker state
    assertEq(broker.fixedPosUuid(), 0);
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
  }

  // score 1K -> score 3K and borrow 500
  function test_supplyAndBorrow() public {
    test_supplyCollateral();

    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 14 days;
    uint256 apr = 105 * 1e25;
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr, termType: type1 });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 newScore = COLLATERAL * 3;
    uint256 borrowAmount = COLLATERAL / 2;
    _generateTree(borrower, newScore, creditToken.versionId() + 1);

    uint256 beforeBalance = creditToken.balanceOf(borrower);
    assertEq(creditToken.balanceOf(address(moolah)), COLLATERAL, "moolah collateral before mismatch");
    assertEq(creditToken.totalSupply(), COLLATERAL, "total supply before mismatch");
    assertEq(USDT.balanceOf(borrower), 0, "borrower loan token balance mismatch before borrow");

    vm.startPrank(borrower);
    creditToken.approve(address(broker), type(uint256).max);
    broker.supplyAndBorrow(marketParams, 2 * COLLATERAL, borrowAmount, termId, newScore, proof);
    vm.stopPrank();

    // Verify global uuid
    assertEq(broker.fixedPosUuid(), 1);

    // Verify a fixed position created
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    assertEq(positions[0].principal, borrowAmount);
    assertEq(positions[0].posId, broker.fixedPosUuid());
    assertEq(positions[0].apr, apr);
    assertEq(positions[0].start, block.timestamp);
    assertEq(positions[0].end, block.timestamp + duration);
    assertEq(positions[0].lastRepaidTime, block.timestamp);
    assertEq(positions[0].interestRepaid, 0);
    assertEq(positions[0].principalRepaid, 0);

    // Check balance
    assertEq(creditToken.balanceOf(borrower), beforeBalance, "should not change borrower collateral balance");
    assertEq(creditToken.balanceOf(address(moolah)), 3 * COLLATERAL, "moolah collateral after mismatch");
    assertEq(creditToken.totalSupply(), 3 * COLLATERAL, "total supply after mismatch");
    assertEq(USDT.balanceOf(borrower), borrowAmount, "borrower loan token balance mismatch after borrow");

    // check position at Moolah
    Position memory pos = moolah.position(marketParams.id(), borrower);
    assertEq(pos.collateral, 3 * COLLATERAL, "moolah position collateral mismatch after supplyAndBorrow");
    assertEq(_principalAtMoolah(borrower), borrowAmount, "moolah position principal mismatch after supplyAndBorrow");
  }

  // score 1K -> score 3K and borrow 3K (max borrowable)
  function test_supplyAndBorrow_MaxBorrow() public {
    test_supplyCollateral();

    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 14 days;
    uint256 apr = 105 * 1e25;
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr, termType: type1 });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 newScore = COLLATERAL * 3;
    uint256 borrowAmount = newScore; // max borrow at 100% LTV
    _generateTree(borrower, newScore, creditToken.versionId() + 1);

    uint256 beforeBalance = creditToken.balanceOf(borrower);
    assertEq(creditToken.balanceOf(address(moolah)), COLLATERAL, "moolah collateral before mismatch");
    assertEq(creditToken.totalSupply(), COLLATERAL, "total supply before mismatch");
    assertEq(USDT.balanceOf(borrower), 0, "borrower loan token balance mismatch before borrow");

    vm.startPrank(borrower);
    creditToken.approve(address(broker), type(uint256).max);
    broker.supplyAndBorrow(marketParams, 2 * COLLATERAL, borrowAmount, termId, newScore, proof);
    vm.stopPrank();

    // Verify global uuid
    assertEq(broker.fixedPosUuid(), 1);

    // Verify a fixed position created
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 1);
    assertEq(positions[0].principal, borrowAmount);
    assertEq(positions[0].posId, broker.fixedPosUuid());
    assertEq(positions[0].apr, apr);
    assertEq(positions[0].start, block.timestamp);
    assertEq(positions[0].end, block.timestamp + duration);
    assertEq(positions[0].lastRepaidTime, block.timestamp);
    assertEq(positions[0].interestRepaid, 0);
    assertEq(positions[0].principalRepaid, 0);

    // Check balance
    assertEq(creditToken.balanceOf(borrower), beforeBalance, "should not change borrower collateral balance");
    assertEq(creditToken.balanceOf(address(moolah)), 3 * COLLATERAL, "moolah collateral after mismatch");
    assertEq(creditToken.totalSupply(), 3 * COLLATERAL, "total supply after mismatch");
    assertEq(USDT.balanceOf(borrower), borrowAmount, "borrower loan token balance mismatch after borrow");

    // check position at Moolah
    Position memory pos = moolah.position(marketParams.id(), borrower);
    assertEq(pos.collateral, 3 * COLLATERAL, "moolah position collateral mismatch after supplyAndBorrow");
    assertEq(_principalAtMoolah(borrower), borrowAmount, "moolah position principal mismatch after supplyAndBorrow");
  }

  // 1K collateral supplied, then full withdraw 1K
  function test_withdrawCollateral_sameScore() public {
    test_supplyCollateral();

    uint256 withdrawAmt = COLLATERAL;
    uint256 beforeBalance = creditToken.balanceOf(borrower);
    uint256 beforeBalanceMoolah = creditToken.balanceOf(address(moolah));

    vm.prank(borrower);
    broker.withdrawCollateral(marketParams, withdrawAmt, COLLATERAL, proof);

    // Check balance
    assertEq(creditToken.balanceOf(borrower) - beforeBalance, withdrawAmt, "withdrawal amount mismatch");
    assertEq(
      beforeBalanceMoolah - creditToken.balanceOf(address(moolah)),
      withdrawAmt,
      "moolah collateral decrease mismatch"
    );

    // Check broker state
    assertEq(broker.fixedPosUuid(), 0);
    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
  }

  // -----------------------------
  // Fixed borrow and repay (partial and full)
  // -----------------------------

  // Supply 1K collateral, borrow 500 fixed, partial repay 100+, then full repay
  function test_fixedBorrowAndPartialRepay_thenFullRepay_noExtension() public {
    test_supplyCollateral();

    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 30 days;
    uint256 apr = 105 * 1e25;

    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr, termType: type1 });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // Borrow fixed
    uint256 fixedAmt = 500 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, termId, COLLATERAL, proof);

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
    USDT.setBalance(borrower, 2_000 ether);
    uint256 repayAll = 2_000 ether;
    moolah.accrueInterest(marketParams);
    vm.prank(borrower);
    broker.repay(repayAll, posId, borrower);

    // Position fully removed
    positions = broker.userFixedPositions(borrower);
    assertEq(positions.length, 0);
  }

  // Supply 1K collateral, borrow 300 fixed, partial repay 40 by 3rd party
  function test_fixedRepayOnBehalfByThirdParty() public {
    test_supplyCollateral();
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 21,
      duration: 45 days,
      apr: 105 * 1e25, // 5% APR
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    uint256 fixedAmt = 300 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, 21, COLLATERAL, proof);

    skip(7 days);

    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    uint256 posId = beforePos.posId;
    uint256 interestDue = CreditBrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    assertGt(interestDue, 0, "interest did not accrue");

    uint256 principalPortion = 40 ether;
    //    uint256 expectedPenalty = BrokerMath.getPenaltyForFixedPosition(beforePos, principalPortion);
    uint256 expectedPenalty = 0; // no early repayment penalty for credit loan
    uint256 repayAmt = interestDue + principalPortion;

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    uint256 helperInitial = repayAmt + 1 ether;

    address helper = address(0x505);
    USDT.setBalance(helper, helperInitial);
    vm.startPrank(helper);
    IERC20(address(USDT)).approve(address(broker), type(uint256).max);
    broker.repay(repayAmt, posId, borrower);
    vm.stopPrank();

    uint256 helperAfter = USDT.balanceOf(helper);
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
    uint256 residualInterest = CreditBrokerMath.getAccruedInterestForFixedPosition(afterPos) - afterPos.interestRepaid;
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
    assertEq(penaltyPaid, expectedPenalty, "early repay penalty should be zero");
    //    assertLt(penaltyPaid - penalty, 5e16, "penalty excess too large");
  }

  // Supply 1K collateral, borrow 350 fixed, full repay by 3rd party after 10 days
  function test_fixedRepayOnBehalfByThirdParty_fullClose() public {
    test_supplyCollateral();
    vm.prank(BOT);
    broker.updateFixedTermAndRate(
      FixedTermAndRate({
        termId: 22,
        duration: 14 days,
        apr: 105 * 1e25, // 5% APR
        termType: type1
      }),
      false
    );

    uint256 fixedAmt = 350 ether;
    vm.prank(borrower);
    broker.borrow(fixedAmt, 22, COLLATERAL, proof);

    skip(10 days);
    moolah.accrueInterest(marketParams);

    (Market memory marketBefore, Position memory posBefore) = _snapshot(borrower);
    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    uint256 posId = beforePos.posId;

    uint256 remainingPrincipal = beforePos.principal - beforePos.principalRepaid;
    uint256 interestDue = CreditBrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    //    uint256 penalty = BrokerMath.getPenaltyForFixedPosition(beforePos, remainingPrincipal);
    uint256 penalty = 0; // no early repayment penalty for credit loan

    uint256 repayAll = 2_000 ether;
    uint256 helperBudget = repayAll + penalty + 1 ether;

    address helper = address(0x6060);
    USDT.setBalance(helper, helperBudget);
    vm.startPrank(helper);
    IERC20(address(USDT)).approve(address(broker), type(uint256).max);
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

    uint256 helperAfter = USDT.balanceOf(helper);
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

  // Supply and borrow 1K, then fully repay during grace period after term end
  function test_fixedRepayDuringGracePeriod_noPenalty() public {
    // add credit broker as provider to moolah
    vm.prank(MANAGER);
    moolah.setProvider(id, address(broker), true);

    uint256 termId = 55;
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: termId,
      duration: 14 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    _generateTree(borrower, COLLATERAL, creditToken.versionId() + 1);

    vm.startPrank(borrower);
    creditToken.approve(address(broker), COLLATERAL);
    broker.supplyAndBorrow(marketParams, COLLATERAL, COLLATERAL, termId, COLLATERAL, proof);
    vm.stopPrank();

    // Advance time to after term end but within grace period, no delay penalty should apply
    skip(15 days);
    moolah.accrueInterest(marketParams);

    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    assertEq(beforePos.principalRepaid, 0, "unexpected principal repaid");
    assertEq(beforePos.interestRepaid, 0, "unexpected interest repaid");
    uint256 posId = beforePos.posId;
    assertFalse(broker.isPositionPenalized(borrower, posId), "position should not be penalized");

    uint256 interestDue = CreditBrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    assertGt(interestDue, 0, "interest did not accrue");
    assertApproxEqAbs(interestDue, 1.9178 ether, 1e14, "unexpected interest due");

    uint256 expectDebt = beforePos.principal - beforePos.principalRepaid + interestDue;

    uint256 debtAmount = 2_000 ether;
    USDT.setBalance(borrower, debtAmount);
    vm.startPrank(borrower);
    USDT.approve(address(broker), debtAmount);
    broker.repayAndWithdraw(marketParams, COLLATERAL, debtAmount, posId, COLLATERAL, proof);

    FixedLoanPosition[] memory afterPositions = broker.userFixedPositions(borrower);
    assertEq(afterPositions.length, 0, "fixed position not removed");

    uint userUsdtBalance = USDT.balanceOf(borrower);
    assertApproxEqAbs(userUsdtBalance, debtAmount - expectDebt, 1e16, "unexpected user USDT balance after repay");
    assertEq(creditToken.balanceOf(borrower), COLLATERAL, "unexpected user collateral balance after withdraw");
  }

  // Supply and borrow 1K, then fully repay after grace period with penalty
  function test_fixedRepayAfterGracePeriod_withPenalty() public {
    // add credit broker as provider to moolah
    vm.prank(MANAGER);
    moolah.setProvider(id, address(broker), true);

    uint256 termId = 66;
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: termId,
      duration: 14 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    _generateTree(borrower, COLLATERAL, creditToken.versionId() + 1);

    vm.startPrank(borrower);
    creditToken.approve(address(broker), COLLATERAL);
    broker.supplyAndBorrow(marketParams, COLLATERAL, COLLATERAL, termId, COLLATERAL, proof);
    vm.stopPrank();

    // Advance time to after grace period
    skip(20 days);
    moolah.accrueInterest(marketParams);

    FixedLoanPosition[] memory beforePositions = broker.userFixedPositions(borrower);
    assertEq(beforePositions.length, 1, "missing fixed position");
    FixedLoanPosition memory beforePos = beforePositions[0];
    assertEq(beforePos.principalRepaid, 0, "unexpected principal repaid");
    assertEq(beforePos.interestRepaid, 0, "unexpected interest repaid");
    uint256 posId = beforePos.posId;
    assertTrue(broker.isPositionPenalized(borrower, posId), "position should be penalized");

    uint256 interestDue = CreditBrokerMath.getAccruedInterestForFixedPosition(beforePos) - beforePos.interestRepaid;
    assertApproxEqAbs(interestDue, 1.9178 ether, 1e14, "unexpected interest due");

    uint256 debt = beforePos.principal - beforePos.principalRepaid + interestDue;

    (, uint penaltyRate) = broker.graceConfig();
    // penalty should be 15% of debt
    uint256 penalty = (debt * penaltyRate) / 1e27; // 15% * repaidAmt
    assertGt(penalty, 0, "penalty did not accrue");
    console.log("calculated penalty: ", penalty);
    debt += penalty;

    uint256 beforeBalance = 2_500 ether;
    USDT.setBalance(borrower, beforeBalance);
    vm.startPrank(borrower);
    USDT.approve(address(broker), beforeBalance);
    broker.repayAndWithdraw(marketParams, COLLATERAL, beforeBalance, posId, COLLATERAL, proof);
    vm.stopPrank();

    FixedLoanPosition[] memory afterPositions = broker.userFixedPositions(borrower);
    assertEq(afterPositions.length, 0, "fixed position not removed");

    uint userUsdtBalance = USDT.balanceOf(borrower);
    assertApproxEqAbs(userUsdtBalance, beforeBalance - debt, 1e16, "unexpected user USDT balance after repay");
    assertEq(creditToken.balanceOf(borrower), COLLATERAL, "unexpected user collateral balance after withdraw");
  }

  function test_provisioning_and_allocation() public {
    // Verify broker wiring
    assertEq(broker.LOAN_TOKEN(), address(USDT));
    assertEq(broker.COLLATERAL_TOKEN(), address(creditToken));

    // Vault should be initialized and approved
    // No automatic supply from vault here; just ensure market exists and supply by supplier occurred
    assertGt(moolah.market(id).totalSupplyAssets, 0, "market has no supply");
  }

  // -----------------------------
  // Edge cases
  // -----------------------------

  function test_borrowZeroAmount_Reverts() public {
    test_supplyCollateral();

    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 111,
      duration: 30 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.expectRevert(bytes("broker/zero-amount"));
    vm.prank(borrower);
    broker.borrow(0, 111, COLLATERAL, proof);
  }

  function test_borrowFixedTermNotFound_Reverts() public {
    vm.expectRevert(bytes("broker/term-not-found"));
    vm.prank(borrower);
    broker.borrow(100 ether, 999, COLLATERAL, proof);
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

  function test_borrowFixed_whenPaused_reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 111,
      duration: 30 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(MANAGER);
    broker.setBorrowPaused(true);

    vm.expectRevert(bytes("Broker/borrow-paused"));
    vm.prank(borrower);
    broker.borrow(1 ether, 111, COLLATERAL, proof);
  }

  function test_borrowFixed_afterUnpause_succeeds() public {
    test_supplyCollateral();
    test_borrowFixed_whenPaused_reverts();

    vm.prank(MANAGER);
    broker.setBorrowPaused(false);

    vm.prank(borrower);
    broker.borrow(100 ether, 111, COLLATERAL, proof);

    assertEq(USDT.balanceOf(borrower), 100 ether);
  }

  function test_setFixedTermOnlyManager_Reverts() public {
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 42,
      duration: 30 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    vm.prank(borrower);
    broker.updateFixedTermAndRate(term, false);
  }

  // Supply 1K collateral, borrow 15 fixed, set max fixed positions to 1, borrow another fixed -> revert
  function test_setMaxFixedLoanPositions_Enforced() public {
    test_supplyCollateral();
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 11,
      duration: 60 days,
      apr: 105 * 1e25,
      termType: type1
    });
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    vm.prank(MANAGER);
    broker.setMaxFixedLoanPositions(1);

    vm.startPrank(borrower);
    broker.borrow(15 ether, 11, COLLATERAL, proof);
    vm.expectRevert(bytes("broker/exceed-max-fixed-positions"));
    broker.borrow(15 ether, 11, COLLATERAL, proof);
    vm.stopPrank();
  }

  function test_peekLoanToken_OneE8() public {
    uint256 p = broker.peek(address(USDT), borrower);
    assertEq(p, 1e8);
  }

  function test_peekCollaterlToken_OneE8() public {
    uint256 p = broker.peek(address(creditToken), borrower);
    assertEq(p, 1e8);
  }

  // Set a fixed term, borrow fixed, wait, then check price reduces
  function test_peekCollateralReducedWithFixedInterest() public {
    test_supplyCollateral();
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 77,
      duration: 30 days,
      apr: 105 * 1e25,
      termType: type1
    });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);
    // initial price from oracle
    uint256 p0 = broker.peek(address(creditToken), borrower);
    vm.prank(borrower);
    broker.borrow(100 ether, 77, COLLATERAL, proof);
    skip(1 days);
    uint256 p1 = broker.peek(address(creditToken), borrower);
    assertLt(p1, p0, "collateral price did not decrease");
  }

  function test_peekUnsupportedToken_Reverts() public {
    vm.expectRevert(bytes("broker/unsupported-token"));
    broker.peek(address(0xDEA), borrower);
  }

  function test_marketIdSet_guard_reverts() public {
    // Deploy a second broker without setting market id
    CreditBroker bImpl2 = new CreditBroker(address(moolah), address(vault), address(oracle), address(LISTA));
    ERC1967Proxy bProxy2 = new ERC1967Proxy(
      address(bImpl2),
      abi.encodeWithSelector(CreditBroker.initialize.selector, ADMIN, MANAGER, BOT, PAUSER, 10)
    );
    CreditBroker broker2 = CreditBroker(payable(address(bProxy2)));

    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 30 days;
    uint256 apr = 105 * 1e25;

    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr, termType: type1 });

    vm.prank(BOT);
    broker2.updateFixedTermAndRate(term, false);

    vm.expectRevert(bytes("Broker/market-not-set"));
    vm.prank(borrower);
    broker2.borrow(1 ether, termId, COLLATERAL, proof);
  }

  function test_setMarketId_onlyOnce_reverts() public {
    vm.expectRevert(bytes("broker/invalid-market"));
    vm.prank(MANAGER);
    broker.setMarketId(id);
  }

  function test_setFixedTerm_validations_revert() public {
    FixedTermAndRate memory term1 = FixedTermAndRate({
      termId: 0,
      duration: 30 days,
      apr: 105 * 1e25,
      termType: type1
    });
    FixedTermAndRate memory term2 = FixedTermAndRate({ termId: 1, duration: 0, apr: 105 * 1e25, termType: type1 });
    FixedTermAndRate memory term3 = FixedTermAndRate({ termId: 2, duration: 90 days, apr: 0, termType: type1 });
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
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 3, duration: 10 days, apr: 105 * 1e25, termType: type1 });
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
    FixedTermAndRate memory term = FixedTermAndRate({ termId: 5, duration: 7 days, apr: 105 * 1e25, termType: type1 });
    FixedTermAndRate memory updatedTerm = FixedTermAndRate({
      termId: 5,
      duration: 14 days,
      apr: 110 * 1e25,
      termType: type1
    });
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

  function test_peek_otherUser_noCollateral_returnsOraclePrice() public {
    // another user with no collateral
    address other = address(0xBEEF);
    uint256 priceFromOracle = broker.peek(address(creditToken));
    uint256 peeked = broker.peek(address(creditToken), other);
    assertEq(peeked, priceFromOracle);
  }

  function test_setMaxFixedLoanPositions_sameValue_reverts() public {
    // default is 10 (from initialize)
    vm.expectRevert(bytes("broker/same-value-provided"));
    vm.prank(MANAGER);
    broker.setMaxFixedLoanPositions(10);
  }

  function test_checkPositionsBelowMinLoanFixed_reverts() public {
    test_supplyCollateral();
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 100,
      duration: 1 hours,
      apr: 105 * 1e25,
      termType: type1
    });
    // create a short-term fixed position
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.prank(MANAGER);
    moolah.setMinLoanValue(10e8);
    uint256 minLoan = moolah.minLoan(marketParams);
    assertEq(minLoan, 10e18);

    vm.startPrank(borrower);
    broker.borrow(minLoan, term.termId, COLLATERAL, proof);
    vm.stopPrank();

    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    uint256 posId = positions[0].posId;

    vm.prank(borrower);
    vm.expectRevert("remain borrow too low"); // throw from moolah
    broker.repay(minLoan / 2, posId, borrower);
  }

  function test_checkPositionsMeetsMinLoan_allowsFullRepay() public {
    test_supplyCollateral();
    FixedTermAndRate memory term = FixedTermAndRate({
      termId: 100,
      duration: 1 hours,
      apr: 105 * 1e25,
      termType: type1
    });
    // create a short-term fixed position
    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    vm.prank(MANAGER);
    moolah.setMinLoanValue(10e8);
    uint256 minLoan = moolah.minLoan(marketParams);
    assertEq(minLoan, 10e18);

    vm.startPrank(borrower);
    broker.borrow(minLoan, term.termId, COLLATERAL, proof);
    vm.stopPrank();

    FixedLoanPosition[] memory positions = broker.userFixedPositions(borrower);
    uint256 posId = positions[0].posId;

    vm.prank(borrower);
    broker.repay(minLoan, posId, borrower);
  }

  function test_getAccruedInterestForFixedPosition() public {
    // Setup a fixed term product
    uint256 termId = 1;
    uint256 duration = 365 days;
    uint256 apr = 13e26; // 30%
    FixedTermAndRate memory term = FixedTermAndRate({ termId: termId, duration: duration, apr: apr, termType: type1 });

    vm.prank(BOT);
    broker.updateFixedTermAndRate(term, false);

    // mock a fixed position
    FixedLoanPosition memory position = FixedLoanPosition({
      termType: type1,
      posId: 1,
      principal: 1_000 ether,
      apr: apr,
      start: block.timestamp,
      end: block.timestamp + duration,
      lastRepaidTime: block.timestamp,
      interestRepaid: 0,
      principalRepaid: 0
    });

    // skip duration
    skip(365 days);
    uint256 accruedInterest = CreditBrokerMath.getAccruedInterestForFixedPosition(position);
    // expected interest = principal * apr * timeElapsed / YEAR_SECONDS / RATE_SCALE
    uint256 expectedInterest = (1_000 ether * 30) / 100; // 300 ether
    assertApproxEqAbs(accruedInterest, expectedInterest, 1e15, "accrued interest mismatch");

    // skip a few days after expiry, interest should not increase
    skip(10 days);
    assertEq(
      CreditBrokerMath.getAccruedInterestForFixedPosition(position),
      accruedInterest,
      "interest should not increase after term end"
    );
  }

  function test_getPenaltyForCreditPosition_clearDebt() public {
    // mock a grace config
    GraceConfig memory graceConfig = GraceConfig({ period: 3 days, penaltyRate: 15 * 1e25 });

    // skip past end + grace period
    skip(45 days);
    uint256 repayAmt = 1000 ether;
    uint256 remainingPrincipal = 500 ether;
    uint256 accruedInterest = 20 ether;
    uint256 endTime = block.timestamp - 15 days; // should be penalized

    uint256 penalty = CreditBrokerMath.getPenaltyForCreditPosition(
      repayAmt,
      remainingPrincipal,
      accruedInterest,
      endTime,
      graceConfig
    );

    // expected penalty = debt * penaltyRate
    uint256 expectedPenalty = (520 ether * 15) / 100; // 15% * debt

    assertApproxEqAbs(penalty, expectedPenalty, 1e15, "penalty mismatch");
  }

  function test_getPenaltyForCreditPosition_partial() public {
    // mock a grace config
    GraceConfig memory graceConfig = GraceConfig({ period: 3 days, penaltyRate: 15 * 1e25 });

    // skip past end + grace period
    skip(45 days);
    uint256 repayAmt = 510 ether;
    uint256 remainingPrincipal = 500 ether;
    uint256 accruedInterest = 20 ether;
    uint256 endTime = block.timestamp - 15 days; // should be penalized

    uint256 penalty = CreditBrokerMath.getPenaltyForCreditPosition(
      repayAmt,
      remainingPrincipal,
      accruedInterest,
      endTime,
      graceConfig
    );
    // expected penalty = repayAmt * penaltyRate
    uint256 expectedPenalty = (510 ether * 15) / 100; // 15% * repaid amount
    assertApproxEqAbs(penalty, expectedPenalty, 1e15, "penalty mismatch");
  }
}

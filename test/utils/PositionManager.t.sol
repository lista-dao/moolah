// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { OracleMock } from "../../src/moolah/mocks/OracleMock.sol";
import { IrmMockZero } from "../../src/moolah/mocks/IrmMock.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { WBNBMock } from "../../src/moolah/mocks/WBNBMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { BNBProvider } from "../../src/provider/BNBProvider.sol";
import { SlisBNBProvider } from "../../src/provider/SlisBNBProvider.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { RateCalculator } from "../../src/broker/RateCalculator.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";
import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate } from "../../src/broker/interfaces/IBroker.sol";
import { BrokerMath, RATE_SCALE } from "../../src/broker/libraries/BrokerMath.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { InterestRateModel } from "../../src/interest-rate-model/InterestRateModel.sol";
import { FixedRateIrm } from "../../src/interest-rate-model/FixedRateIrm.sol";

import { PositionManager } from "../../src/utils/PositionManager.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";

/// @dev Minimal vault mock satisfying BNBProvider constructor checks (asset() and MOOLAH()).
contract MockMoolahVault {
  address public immutable MOOLAH;
  address private immutable _asset;

  constructor(address _moolah, address asset_) {
    MOOLAH = _moolah;
    _asset = asset_;
  }

  function asset() external view returns (address) {
    return _asset;
  }
}

/// @dev 1:1 StakeManager mock for SlisBNBProvider (slisBNB : BNB = 1 : 1).
contract StakeManagerMock {
  function convertBnbToSnBnb(uint256 amount) external pure returns (uint256) {
    return amount;
  }

  function convertSnBnbToBnb(uint256 amount) external pure returns (uint256) {
    return amount;
  }
}

/// @dev Minimal LP token mock for SlisBNBProvider (open mint/burn, no access control).
contract LpTokenMock is ERC20 {
  constructor() ERC20("Lista LP", "clisBNB") {}

  function mint(address account, uint256 amount) external {
    _mint(account, amount);
  }

  function burn(address account, uint256 amount) external {
    _burn(account, amount);
  }

  function decimals() public pure override returns (uint8) {
    return 18;
  }
}

/// @notice Tests for LendingBroker.borrow(amount, termId, user, receiver) and PositionManager.migrate()
contract PositionManagerTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;

  // ─── Core contracts ───────────────────────────────────────────────────────
  IMoolah public moolah;
  MoolahVault public vault;
  BrokerInterestRelayer public relayer;
  RateCalculator public rateCalc;

  // ─── inMarket: fixed-term market (定期) with LendingBroker ────────────────
  LendingBroker public inBroker;
  MarketParams public inMarket;
  Id public inId;

  // ─── outMarket: variable-rate market (活期), no broker ────────────────────
  MarketParams public outMarket;
  Id public outId;

  // ─── PositionManager ──────────────────────────────────────────────────────
  PositionManager public positionManager;
  PositionManager public positionManagerNative; // WBNB-aware, for BNBProvider test

  // ─── Tokens & oracle ──────────────────────────────────────────────────────
  ERC20Mock public loanToken;
  ERC20Mock public collateralToken;
  OracleMock public oracle;
  InterestRateModel public irm;
  FixedRateIrm public fixedIrm;

  // ─── SlisBNBProvider (ERC20 collateral provider) ──────────────────────────
  ERC20Mock public slisBNB;
  StakeManagerMock public stakeManager;
  LpTokenMock public lpToken;
  SlisBNBProvider public slisBNBProvider;
  LendingBroker public inBrokerSlis;
  MarketParams public outMarketSlis;
  MarketParams public inMarketSlis;
  Id public outIdSlis;
  Id public inIdSlis;

  // ─── BNBProvider (native-token collateral provider) ───────────────────────
  WBNBMock public wbnb;
  MockMoolahVault public wbnbVaultMock;
  BNBProvider public bnbProvider;
  LendingBroker public inBrokerNative;
  MarketParams public outMarketNative;
  MarketParams public inMarketNative;
  Id public outIdNative;
  Id public inIdNative;

  // ─── Roles ────────────────────────────────────────────────────────────────
  address admin;
  address manager;
  address bot;
  address pauser;

  // ─── Test participants ────────────────────────────────────────────────────
  address supplier;
  address user;
  address receiver;

  // ─── Constants ────────────────────────────────────────────────────────────
  uint256 lltv = 0.8 ether;
  uint256 constant COLLATERAL = 10000 ether;
  uint256 constant SUPPLY_LIQ = 200 ether;
  uint256 constant BORROW_AMOUNT = 100 ether;

  // Fixed term added to inBroker
  uint256 constant TERM_ID = 1;
  uint256 constant TERM_DURATION = 30 days;
  uint256 constant TERM_APR = 105 * 1e25; // 5% APR

  function setUp() public {
    admin = makeAddr("admin");
    manager = makeAddr("manager");
    bot = makeAddr("bot");
    pauser = makeAddr("pauser");
    supplier = makeAddr("supplier");
    user = makeAddr("user");
    receiver = makeAddr("receiver");

    // ── Deploy Moolah ────────────────────────────────────────────────────────
    Moolah mImpl = new Moolah();
    ERC1967Proxy mProxy = new ERC1967Proxy(
      address(mImpl),
      abi.encodeWithSelector(Moolah.initialize.selector, admin, manager, pauser, 0)
    );
    moolah = IMoolah(address(mProxy));

    // ── Tokens ───────────────────────────────────────────────────────────────
    oracle = new OracleMock();

    loanToken = new ERC20Mock();
    loanToken.setDecimals(18);
    collateralToken = new ERC20Mock();
    collateralToken.setDecimals(18);

    wbnb = new WBNBMock();
    slisBNB = new ERC20Mock();
    slisBNB.setDecimals(18);

    oracle = new OracleMock();
    oracle.setPrice(address(loanToken), 1e8);
    oracle.setPrice(address(collateralToken), 1e8);
    oracle.setPrice(address(wbnb), 1e8);
    oracle.setPrice(address(slisBNB), 1e8);

    // ── IRM & LLTV ───────────────────────────────────────────────────────────
    InterestRateModel irmImpl = new InterestRateModel(address(moolah));
    ERC1967Proxy irmProxy = new ERC1967Proxy(
      address(irmImpl),
      abi.encodeWithSelector(InterestRateModel.initialize.selector, admin)
    );
    irm = InterestRateModel(address(irmProxy));

    FixedRateIrm fixedIrmImpl = new FixedRateIrm();
    ERC1967Proxy fixedIrmProxy = new ERC1967Proxy(
      address(fixedIrmImpl),
      abi.encodeWithSelector(FixedRateIrm.initialize.selector, admin, manager)
    );
    fixedIrm = FixedRateIrm(address(fixedIrmProxy));

    vm.startPrank(manager);
    Moolah(address(moolah)).enableIrm(address(irm));
    Moolah(address(moolah)).enableIrm(address(fixedIrm));
    Moolah(address(moolah)).enableLltv(lltv);
    vm.stopPrank();

    // ── Vault & relayer (required by LendingBroker) ──────────────────────────
    vault = new MoolahVault(address(moolah), address(loanToken));
    BrokerInterestRelayer relayerImpl = new BrokerInterestRelayer();
    ERC1967Proxy relayerProxy = new ERC1967Proxy(
      address(relayerImpl),
      abi.encodeWithSelector(
        BrokerInterestRelayer.initialize.selector,
        admin,
        manager,
        address(moolah),
        address(vault),
        address(loanToken)
      )
    );
    relayer = BrokerInterestRelayer(address(relayerProxy));

    // ── RateCalculator ───────────────────────────────────────────────────────
    RateCalculator rcImpl = new RateCalculator();
    ERC1967Proxy rcProxy = new ERC1967Proxy(
      address(rcImpl),
      abi.encodeWithSelector(RateCalculator.initialize.selector, admin, manager, bot)
    );
    rateCalc = RateCalculator(address(rcProxy));

    // ── Deploy inBroker (LendingBroker for the fixed-term market) ────────────
    LendingBroker bImpl = new LendingBroker(address(moolah), address(wbnb));
    ERC1967Proxy bProxy = new ERC1967Proxy(
      address(bImpl),
      abi.encodeWithSelector(
        LendingBroker.initialize.selector,
        admin,
        manager,
        bot,
        pauser,
        address(rateCalc),
        100,
        address(relayer),
        address(oracle)
      )
    );
    inBroker = LendingBroker(payable(address(bProxy)));

    // ── Create inMarket (定期, uses inBroker as oracle) ───────────────────────
    inMarket = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(inBroker),
      irm: address(fixedIrm),
      lltv: lltv
    });
    inId = inMarket.id();
    Moolah(address(moolah)).createMarket(inMarket);

    vm.startPrank(manager);
    inBroker.setMarketId(inId);
    rateCalc.registerBroker(address(inBroker), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(inId, address(inBroker), true);
    vm.stopPrank();

    vm.prank(manager);
    relayer.addBroker(address(inBroker));

    // ── Create outMarket (活期, no broker, uses oracle directly) ──────────────
    outMarket = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });
    outId = outMarket.id();
    Moolah(address(moolah)).createMarket(outMarket);

    // ── Add fixed term to inBroker ────────────────────────────────────────────
    vm.prank(bot);
    inBroker.updateFixedTermAndRate(
      FixedTermAndRate({ termId: TERM_ID, duration: TERM_DURATION, apr: TERM_APR }),
      false
    );

    // ── Seed both markets with liquidity ─────────────────────────────────────
    loanToken.setBalance(supplier, SUPPLY_LIQ);
    vm.startPrank(supplier);
    IERC20(address(loanToken)).approve(address(moolah), type(uint256).max);
    moolah.supply(outMarket, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    moolah.supply(inMarket, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    vm.stopPrank();

    // ── User deposits collateral into outMarket and borrows ───────────────────
    collateralToken.setBalance(user, COLLATERAL);
    vm.startPrank(user);
    collateralToken.approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(outMarket, COLLATERAL, user, bytes(""));
    moolah.borrow(outMarket, BORROW_AMOUNT, 0, user, user);
    vm.stopPrank();

    // ── Deploy PositionManager (no native token) ──────────────────────────────
    PositionManager positionManagerImpl = new PositionManager(address(moolah), address(wbnb));
    ERC1967Proxy positionManagerProxy = new ERC1967Proxy(
      address(positionManagerImpl),
      abi.encodeWithSelector(PositionManager.initialize.selector, admin, manager)
    );
    positionManager = PositionManager(payable(address(positionManagerProxy)));

    // ── User approvals for repay ──────────────────────────────────────────────
    vm.prank(user);
    loanToken.approve(address(inBroker), type(uint256).max);

    // ════════════════════════════════════════════════════════════════════════
    //  SlisBNBProvider setup
    // ════════════════════════════════════════════════════════════════════════

    stakeManager = new StakeManagerMock();
    lpToken = new LpTokenMock();

    // ── Deploy inBrokerSlis ───────────────────────────────────────────────────
    {
      LendingBroker bSlisImpl = new LendingBroker(address(moolah), address(wbnb));
      ERC1967Proxy bSlisProxy = new ERC1967Proxy(
        address(bSlisImpl),
        abi.encodeWithSelector(
          LendingBroker.initialize.selector,
          admin,
          manager,
          bot,
          pauser,
          address(rateCalc),
          100,
          address(relayer),
          address(oracle)
        )
      );
      inBrokerSlis = LendingBroker(payable(address(bSlisProxy)));
    }

    // ── Create slisBNB markets ────────────────────────────────────────────────
    outMarketSlis = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(slisBNB),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });
    Moolah(address(moolah)).createMarket(outMarketSlis);
    outIdSlis = outMarketSlis.id();

    inMarketSlis = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(slisBNB),
      oracle: address(inBrokerSlis),
      irm: address(fixedIrm),
      lltv: lltv
    });
    Moolah(address(moolah)).createMarket(inMarketSlis);
    inIdSlis = inMarketSlis.id();

    vm.startPrank(manager);
    inBrokerSlis.setMarketId(inIdSlis);
    rateCalc.registerBroker(address(inBrokerSlis), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(inIdSlis, address(inBrokerSlis), true);
    vm.stopPrank();

    vm.prank(manager);
    relayer.addBroker(address(inBrokerSlis));

    vm.prank(bot);
    inBrokerSlis.updateFixedTermAndRate(
      FixedTermAndRate({ termId: TERM_ID, duration: TERM_DURATION, apr: TERM_APR }),
      false
    );

    // ── Seed slisBNB markets with liquidity ───────────────────────────────────
    loanToken.setBalance(supplier, SUPPLY_LIQ);
    vm.startPrank(supplier);
    moolah.supply(outMarketSlis, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    moolah.supply(inMarketSlis, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    vm.stopPrank();

    // ── Deploy SlisBNBProvider via proxy ──────────────────────────────────────
    {
      SlisBNBProvider slisImpl = new SlisBNBProvider(
        address(moolah),
        address(slisBNB),
        address(stakeManager),
        address(lpToken)
      );
      ERC1967Proxy slisProxy = new ERC1967Proxy(
        address(slisImpl),
        abi.encodeWithSelector(SlisBNBProvider.initialize.selector, admin, manager, uint128(1e18))
      );
      slisBNBProvider = SlisBNBProvider(address(slisProxy));
    }

    // ── Register SlisBNBProvider for both slisBNB markets ────────────────────
    vm.startPrank(manager);
    Moolah(address(moolah)).setProvider(outIdSlis, address(slisBNBProvider), true);
    Moolah(address(moolah)).setProvider(inIdSlis, address(slisBNBProvider), true);
    vm.stopPrank();

    // ── User supplies slisBNB via provider and borrows ────────────────────────
    slisBNB.setBalance(user, COLLATERAL);
    vm.startPrank(user);
    slisBNB.approve(address(slisBNBProvider), type(uint256).max);
    slisBNBProvider.supplyCollateral(outMarketSlis, COLLATERAL, user, "");
    moolah.borrow(outMarketSlis, BORROW_AMOUNT, 0, user, user);
    loanToken.approve(address(inBrokerSlis), type(uint256).max);
    vm.stopPrank();

    // ════════════════════════════════════════════════════════════════════════
    //  BNBProvider setup
    // ════════════════════════════════════════════════════════════════════════

    // ── Deploy inBrokerNative ─────────────────────────────────────────────────
    {
      LendingBroker bNativeImpl = new LendingBroker(address(moolah), address(wbnb));
      ERC1967Proxy bNativeProxy = new ERC1967Proxy(
        address(bNativeImpl),
        abi.encodeWithSelector(
          LendingBroker.initialize.selector,
          admin,
          manager,
          bot,
          pauser,
          address(rateCalc),
          10,
          address(relayer),
          address(oracle)
        )
      );
      inBrokerNative = LendingBroker(payable(address(bNativeProxy)));
    }

    // ── Create WBNB markets ───────────────────────────────────────────────────
    outMarketNative = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(wbnb),
      oracle: address(oracle),
      irm: address(irm),
      lltv: lltv
    });
    Moolah(address(moolah)).createMarket(outMarketNative);
    outIdNative = outMarketNative.id();

    inMarketNative = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(wbnb),
      oracle: address(inBrokerNative),
      irm: address(fixedIrm),
      lltv: lltv
    });
    Moolah(address(moolah)).createMarket(inMarketNative);
    inIdNative = inMarketNative.id();

    vm.startPrank(manager);
    inBrokerNative.setMarketId(inIdNative);
    rateCalc.registerBroker(address(inBrokerNative), RATE_SCALE + 1, RATE_SCALE + 2);
    Moolah(address(moolah)).setMarketBroker(inIdNative, address(inBrokerNative), true);
    vm.stopPrank();

    vm.prank(manager);
    relayer.addBroker(address(inBrokerNative));

    vm.prank(bot);
    inBrokerNative.updateFixedTermAndRate(
      FixedTermAndRate({ termId: TERM_ID, duration: TERM_DURATION, apr: TERM_APR }),
      false
    );

    // ── Seed WBNB markets with liquidity ──────────────────────────────────────
    loanToken.setBalance(supplier, SUPPLY_LIQ);
    vm.startPrank(supplier);
    moolah.supply(outMarketNative, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    moolah.supply(inMarketNative, SUPPLY_LIQ / 2, 0, supplier, bytes(""));
    vm.stopPrank();

    // ── Deploy BNBProvider via proxy ──────────────────────────────────────────
    wbnbVaultMock = new MockMoolahVault(address(moolah), address(wbnb));
    {
      BNBProvider bnbImpl = new BNBProvider(address(moolah), address(wbnbVaultMock), address(wbnb));
      ERC1967Proxy bnbProxy = new ERC1967Proxy(
        address(bnbImpl),
        abi.encodeWithSelector(BNBProvider.initialize.selector, admin, manager)
      );
      bnbProvider = BNBProvider(payable(address(bnbProxy)));
    }

    // ── Register BNBProvider before user deposits ─────────────────────────────
    vm.startPrank(manager);
    Moolah(address(moolah)).setProvider(outIdNative, address(bnbProvider), true);
    Moolah(address(moolah)).setProvider(inIdNative, address(bnbProvider), true);
    vm.stopPrank();

    // ── User supplies WBNB via BNBProvider and borrows ────────────────────────
    vm.deal(user, COLLATERAL);
    vm.startPrank(user);
    bnbProvider.supplyCollateral{ value: COLLATERAL }(outMarketNative, user, "");
    moolah.borrow(outMarketNative, BORROW_AMOUNT, 0, user, user);
    loanToken.approve(address(inBrokerNative), type(uint256).max);
    vm.stopPrank();

    // ── PositionManager with WBNB set (for native-token migrations) ───────────
    positionManagerNative = new PositionManager(address(moolah), address(wbnb));
  }

  /// @notice Reverts when user has not authorized PositionManager in Moolah.
  function test_migrate_revertsIfNotAuthorized() public {
    vm.prank(user);
    vm.expectRevert("not-authorized");
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, BORROW_AMOUNT, 0, TERM_ID);
  }

  /// @notice Reverts when both borrowAmount and borrowShares are zero.
  function test_migrate_revertsOnZeroBorrowAmountAndShares() public {
    vm.startPrank(user);
    moolah.setAuthorization(address(positionManager), true);
    vm.expectRevert("exactly-one-of-borrowAmount-or-borrowShares");
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, 0, 0, TERM_ID);
    vm.stopPrank();
  }

  /// @notice Reverts when collateralAmount is zero.
  function test_migrate_revertsOnZeroCollateralAmount() public {
    vm.startPrank(user);
    moolah.setAuthorization(address(positionManager), true);
    vm.expectRevert("zero-collateral-amount");
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, 0, BORROW_AMOUNT, 0, TERM_ID);
    vm.stopPrank();
  }

  /// @notice Reverts when inMarket has no registered broker.
  function test_migrate_revertsWhenNoBroker() public {
    // outMarket also has no broker — try migrating into outMarket
    vm.startPrank(user);
    moolah.setAuthorization(address(positionManager), true);
    vm.expectRevert("no-broker-for-market");
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, outMarket, COLLATERAL, BORROW_AMOUNT, 0, TERM_ID);
    vm.stopPrank();
  }

  /// @notice Full migration: outMarket variable position moves to inMarket fixed position.
  function test_migrate_fullMigration() public {
    // ── Snapshot before ───────────────────────────────────────────────────────
    Position memory outPosBefore = moolah.position(outId, user);
    assertGt(outPosBefore.borrowShares, 0, "user should have borrow in outMarket before");
    assertGt(outPosBefore.collateral, 0, "user should have collateral in outMarket before");

    // ── Authorize PositionManager ─────────────────────────────────────────────
    vm.prank(user);
    moolah.setAuthorization(address(positionManager), true);

    // ── Execute migration ─────────────────────────────────────────────────────
    vm.prank(user);
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, BORROW_AMOUNT, 0, TERM_ID);

    // ── Assertions ────────────────────────────────────────────────────────────

    // outMarket: collateral withdrawn and debt repaid
    Position memory outPosAfter = moolah.position(outId, user);
    assertEq(outPosAfter.collateral, 0, "outMarket collateral should be 0 after migration");
    assertEq(outPosAfter.borrowShares, 0, "outMarket borrow should be 0 after migration");

    // inMarket: collateral deposited
    Position memory inPosAfter = moolah.position(inId, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarket collateral should equal migrated amount");

    // inBroker: fixed position created for user
    FixedLoanPosition[] memory positions = inBroker.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position in inBroker");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");
    assertEq(positions[0].apr, TERM_APR, "fixed position apr mismatch");

    // PositionManager should hold no tokens after migration
    assertEq(loanToken.balanceOf(address(positionManager)), 0, "positionManager should hold no loan tokens");
    assertEq(
      collateralToken.balanceOf(address(positionManager)),
      0,
      "positionManager should hold no collateral tokens"
    );
  }

  /// @notice Partial migration: only part of the collateral and debt is migrated.
  function test_migrate_partialMigration() public {
    uint256 partialCollateral = COLLATERAL / 2;
    uint256 partialBorrow = BORROW_AMOUNT / 2;

    vm.prank(user);
    moolah.setAuthorization(address(positionManager), true);

    vm.prank(user);
    positionManager.migrateCommonMarketToFixedTermMarket(
      outMarket,
      inMarket,
      partialCollateral,
      partialBorrow,
      0,
      TERM_ID
    );

    // outMarket: half collateral and half borrow remain
    Position memory outPosAfter = moolah.position(outId, user);
    assertEq(outPosAfter.collateral, COLLATERAL - partialCollateral, "outMarket collateral should be halved");
    assertGt(outPosAfter.borrowShares, 0, "outMarket borrow shares should remain");

    // inMarket: half collateral deposited
    Position memory inPosAfter = moolah.position(inId, user);
    assertEq(inPosAfter.collateral, partialCollateral, "inMarket collateral should be half");

    // inBroker: fixed position for partial borrow
    FixedLoanPosition[] memory positions = inBroker.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position");
    assertEq(positions[0].principal, partialBorrow, "fixed position principal should be half");
  }

  /// @notice Full migration using borrowShares: exact debt repayment by shares.
  function test_migrate_fullMigrationByShares() public {
    // ── Snapshot before ───────────────────────────────────────────────────────
    Position memory outPosBefore = moolah.position(outId, user);
    uint256 userBorrowShares = outPosBefore.borrowShares;
    assertGt(userBorrowShares, 0, "user should have borrow in outMarket before");

    // ── Authorize PositionManager ─────────────────────────────────────────────
    vm.prank(user);
    moolah.setAuthorization(address(positionManager), true);

    // ── Execute migration by shares ───────────────────────────────────────────
    vm.prank(user);
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, 0, userBorrowShares, TERM_ID);

    // ── Assertions ────────────────────────────────────────────────────────────

    // outMarket: collateral withdrawn and debt fully repaid
    Position memory outPosAfter = moolah.position(outId, user);
    assertEq(outPosAfter.collateral, 0, "outMarket collateral should be 0 after migration");
    assertEq(outPosAfter.borrowShares, 0, "outMarket borrow should be 0 after migration");

    // inMarket: collateral deposited
    Position memory inPosAfter = moolah.position(inId, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarket collateral should equal migrated amount");

    // inBroker: fixed position created for user
    FixedLoanPosition[] memory positions = inBroker.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position in inBroker");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");

    // PositionManager should hold no tokens after migration
    assertEq(loanToken.balanceOf(address(positionManager)), 0, "positionManager should hold no loan tokens");
    assertEq(
      collateralToken.balanceOf(address(positionManager)),
      0,
      "positionManager should hold no collateral tokens"
    );
  }

  /// @notice Full migration using borrowShares with SlisBNBProvider.
  function test_migrate_withSlisBNBProviderByShares() public {
    Position memory outPosBefore = moolah.position(outIdSlis, user);
    uint256 userBorrowShares = outPosBefore.borrowShares;

    vm.prank(user);
    moolah.setAuthorization(address(positionManager), true);

    vm.prank(user);
    positionManager.migrateCommonMarketToFixedTermMarket(
      outMarketSlis,
      inMarketSlis,
      COLLATERAL,
      0,
      userBorrowShares,
      TERM_ID
    );

    Position memory outPosAfter = moolah.position(outIdSlis, user);
    assertEq(outPosAfter.collateral, 0, "outMarketSlis collateral should be 0");
    assertEq(outPosAfter.borrowShares, 0, "outMarketSlis borrow shares should be 0");

    Position memory inPosAfter = moolah.position(inIdSlis, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarketSlis collateral should equal migrated amount");

    FixedLoanPosition[] memory positions = inBrokerSlis.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");
  }

  /// @notice Full migration using borrowShares with BNBProvider.
  function test_migrate_withBNBProviderByShares() public {
    Position memory outPosBefore = moolah.position(outIdNative, user);
    uint256 userBorrowShares = outPosBefore.borrowShares;

    vm.prank(user);
    moolah.setAuthorization(address(positionManagerNative), true);

    vm.prank(user);
    positionManagerNative.migrateCommonMarketToFixedTermMarket(
      outMarketNative,
      inMarketNative,
      COLLATERAL,
      0,
      userBorrowShares,
      TERM_ID
    );

    Position memory outPosAfter = moolah.position(outIdNative, user);
    assertEq(outPosAfter.collateral, 0, "outMarketNative collateral should be 0");
    assertEq(outPosAfter.borrowShares, 0, "outMarketNative borrow shares should be 0");

    Position memory inPosAfter = moolah.position(inIdNative, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarketNative collateral should equal migrated amount");

    FixedLoanPosition[] memory positions = inBrokerNative.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");
  }

  /// @notice After migration, PositionManager's authorization can be revoked without issue.
  function test_migrate_deauthorize() public {
    vm.startPrank(user);
    moolah.setAuthorization(address(positionManager), true);
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, BORROW_AMOUNT, 0, TERM_ID);
    moolah.setAuthorization(address(positionManager), false);
    vm.stopPrank();

    // Subsequent migration attempt reverts as expected
    vm.prank(user);
    vm.expectRevert("not-authorized");
    positionManager.migrateCommonMarketToFixedTermMarket(outMarket, inMarket, COLLATERAL, BORROW_AMOUNT, 0, TERM_ID);
  }

  /// @notice onMoolahFlashLoan reverts if called by anyone other than Moolah.
  function test_migrate_flashLoanCallbackOnlyMoolah() public {
    bytes memory data = abi.encode(
      PositionManager.MigrateParams({
        outMarket: outMarket,
        inMarket: inMarket,
        collateralAmount: COLLATERAL,
        borrowShares: 0,
        termId: TERM_ID,
        user: user
      })
    );

    vm.prank(address(0xBAD));
    vm.expectRevert("invalid-caller");
    positionManager.onMoolahFlashLoan(BORROW_AMOUNT, data);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PositionManager with SlisBNBProvider (ERC20 collateral provider)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Full migration succeeds when both markets have SlisBNBProvider registered as collateral provider.
  function test_migrate_withSlisBNBProvider() public {
    vm.prank(user);
    moolah.setAuthorization(address(positionManager), true);

    vm.prank(user);
    positionManager.migrateCommonMarketToFixedTermMarket(
      outMarketSlis,
      inMarketSlis,
      COLLATERAL,
      BORROW_AMOUNT,
      0,
      TERM_ID
    );

    // outMarketSlis: fully cleared
    Position memory outPosAfter = moolah.position(outIdSlis, user);
    assertEq(outPosAfter.collateral, 0, "outMarketSlis collateral should be 0");
    assertEq(outPosAfter.borrowShares, 0, "outMarketSlis borrow shares should be 0");

    // inMarketSlis: collateral deposited
    Position memory inPosAfter = moolah.position(inIdSlis, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarketSlis collateral should equal migrated amount");

    // inBrokerSlis: fixed position created for user
    FixedLoanPosition[] memory positions = inBrokerSlis.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");

    // PositionManager holds no residual tokens
    assertEq(loanToken.balanceOf(address(positionManager)), 0, "positionManager should hold no loan tokens");
    assertEq(slisBNB.balanceOf(address(positionManager)), 0, "positionManager should hold no slisBNB");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PositionManager with BNBProvider (native-token collateral provider)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Full migration succeeds when both markets have BNBProvider registered as collateral provider.
  function test_migrate_withBNBProvider() public {
    vm.prank(user);
    moolah.setAuthorization(address(positionManagerNative), true);

    vm.prank(user);
    positionManagerNative.migrateCommonMarketToFixedTermMarket(
      outMarketNative,
      inMarketNative,
      COLLATERAL,
      BORROW_AMOUNT,
      0,
      TERM_ID
    );

    // outMarketNative: fully cleared
    Position memory outPosAfter = moolah.position(outIdNative, user);
    assertEq(outPosAfter.collateral, 0, "outMarketNative collateral should be 0");
    assertEq(outPosAfter.borrowShares, 0, "outMarketNative borrow shares should be 0");

    // inMarketNative: collateral deposited
    Position memory inPosAfter = moolah.position(inIdNative, user);
    assertEq(inPosAfter.collateral, COLLATERAL, "inMarketNative collateral should equal migrated amount");

    // inBrokerNative: fixed position created for user
    FixedLoanPosition[] memory positions = inBrokerNative.userFixedPositions(user);
    assertEq(positions.length, 1, "user should have 1 fixed position in inBrokerNative");
    assertEq(positions[0].principal, BORROW_AMOUNT, "fixed position principal mismatch");

    // positionManagerNative holds no residual tokens
    assertEq(address(positionManagerNative).balance, 0, "positionManagerNative should hold no native BNB");
    assertEq(
      IERC20(address(wbnb)).balanceOf(address(positionManagerNative)),
      0,
      "positionManagerNative should hold no WBNB"
    );
  }

  /// @notice emergencyWithdraw reverts if called by non-admin, and succeeds for manager.
  function test_emergencyWithdraw() public {
    // Emergency withdraw by non-admin should revert
    vm.prank(user);
    vm.expectRevert();
    positionManager.emergencyWithdraw(address(loanToken), 1 ether);

    deal(address(positionManager), 1 ether);
    deal(address(loanToken), address(positionManager), 1 ether);
    // Emergency withdraw by manager should succeed
    uint256 balanceBefore = loanToken.balanceOf(admin);
    uint256 balanceBeforeNative = address(manager).balance;
    vm.startPrank(manager);
    positionManager.emergencyWithdraw(address(loanToken), 1 ether);
    positionManager.emergencyWithdraw(address(0), 1 ether);
    vm.stopPrank();
    uint256 balanceAfter = loanToken.balanceOf(manager);
    uint256 balanceAfterNative = address(manager).balance;
    assertEq(balanceAfter - balanceBefore, 1 ether, "manager should receive withdrawn tokens");
    assertEq(balanceAfterNative - balanceBeforeNative, 1 ether, "manager should receive withdrawn native tokens");
  }
}

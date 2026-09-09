// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MathLib } from "moolah/libraries/MathLib.sol";
import { ORACLE_PRICE_SCALE } from "moolah/libraries/ConstantsLib.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";
import { YieldAccount } from "../../src/utils/YieldAccount.sol";
import { IYieldAccount } from "../../src/utils/interfaces/IYieldAccount.sol";
import { ISlisBnbProvider } from "../../src/provider/interfaces/IProvider.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";
import { ISlisBNBxMinter } from "../../src/utils/interfaces/ISlisBNBx.sol";

contract YieldAccountForkTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using MathLib for uint256;

  uint256 constant FORK_BLOCK = 116_433_631;

  IMoolah constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  ISlisBnbProvider constant PROVIDER = ISlisBnbProvider(0x33f7A980a246f9B8FEA2254E3065576E127D4D5f);
  IERC20 constant SLISBNB = IERC20(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B);
  IERC20 constant LISUSD = IERC20(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);
  address constant MULTI_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address constant ALPHA_IRM = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  IStakeManager stakeManager;
  MarketParams params;
  Id id;
  YieldAccount account;

  address owner = makeAddr("accountOwner");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address treasury = makeAddr("treasury");
  address keeper = makeAddr("keeper");
  address donor = makeAddr("donor");
  address migrator = makeAddr("migrator");
  address stranger = makeAddr("stranger");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    params = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(SLISBNB),
      oracle: MULTI_ORACLE,
      irm: ALPHA_IRM,
      lltv: 85 * 1e16
    });
    id = params.id();
    require(MOOLAH.market(id).lastUpdate != 0, "market missing at fork block");
    require(MOOLAH.providers(id, address(SLISBNB)) == address(PROVIDER), "provider mismatch");

    stakeManager = IStakeManager(PROVIDER.STAKE_MANAGER());

    address[] memory receivers = new address[](1);
    receivers[0] = owner;

    YieldAccount impl = new YieldAccount(address(MOOLAH), address(PROVIDER), owner);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(
        YieldAccount.initialize,
        (TIMELOCK, manager, pauser, params, treasury, 0.001 ether, owner, receivers)
      )
    );
    account = YieldAccount(address(proxy));
  }

  /* ----------------------------- helpers ----------------------------- */

  function _depositSlis(uint256 amount) internal returns (uint256 bnbValue) {
    deal(address(SLISBNB), owner, amount);
    bnbValue = stakeManager.convertSnBnbToBnb(amount);
    vm.startPrank(owner);
    SLISBNB.approve(address(account), amount);
    account.depositSlisBnb(amount);
    vm.stopPrank();
  }

  /// @dev collateral supplied straight through the provider, outside the account's accounting —
  ///      indistinguishable from exchange-rate yield for skim purposes
  function _donate(uint256 amount) internal {
    deal(address(SLISBNB), donor, amount);
    vm.startPrank(donor);
    SLISBNB.approve(address(PROVIDER), amount);
    PROVIDER.supplyCollateral(params, amount, address(account), "");
    vm.stopPrank();
  }

  function _maxBorrow() internal view returns (uint256) {
    uint256 coll = account.collateral();
    uint256 price = MOOLAH.getPrice(params);
    return coll.mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(params.lltv);
  }

  /// @dev borrow() skims first, so unskimmed yield must come off the collateral before the cap is
  ///      computed — using _maxBorrow() with yield pending reverts `insufficient collateral`
  function _maxBorrowAfterSkim() internal view returns (uint256) {
    (uint256 skimSlis, ) = account.skimmable();
    uint256 coll = account.collateral() - skimSlis;
    uint256 price = MOOLAH.getPrice(params);
    return coll.mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(params.lltv);
  }

  /* ----------------------------- accounting views ----------------------------- */

  /// @dev parity with MoolahVaultAccount's claimableYield / previewClaim
  function test_claimableYield_and_previewSkim() public {
    _depositSlis(1000 ether);
    assertEq(account.claimableYield(), 0);

    _donate(50 ether);
    uint256 claimable = account.claimableYield();
    // 50 slisBNB UNITS, so the BNB value is 50 x the exchange rate
    assertApproxEqAbs(claimable, stakeManager.convertSnBnbToBnb(50 ether), 1e12);

    (uint256 pClaimable, uint256 pSlis, uint256 pBnb) = account.previewSkim();
    (uint256 sSlis, uint256 sBnb) = account.skimmable();
    assertEq(pClaimable, claimable);
    assertEq(pSlis, sSlis);
    assertEq(pBnb, sBnb);

    // with debt outstanding the two figures must stay consistent: what a skim can take now never
    // exceeds the accounting surplus. The capped case itself is test_skim_healthCapped.
    uint256 borrowAmount = _maxBorrowAfterSkim() - 1e18;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    _donate(50 ether);
    (uint256 c2, , uint256 s2Bnb) = account.previewSkim();
    assertGt(c2, 0);
    assertLe(s2Bnb, c2);
  }

  /// @dev the mirrors must be exact: borrowing / withdrawing exactly what they report must succeed,
  ///      and one wei more must revert
  function test_borrowable_isExact() public {
    _depositSlis(1000 ether);
    _donate(50 ether); // unskimmed yield must not inflate the cap

    uint256 quote = account.borrowable();
    assertGt(quote, 0);

    // one wei over the quote is rejected by Moolah's own health check
    vm.prank(owner);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    account.borrow(quote + 1e12, owner);

    // exactly the quote goes through
    vm.prank(owner);
    account.borrow(quote, owner);
    assertEq(LISUSD.balanceOf(owner), quote);
    // and there is nothing left to borrow
    assertLe(account.borrowable(), 1e12);
  }

  function test_borrowable_excludesUnskimmedYield() public {
    _depositSlis(1000 ether);
    uint256 before = account.borrowable();

    _donate(200 ether); // 20% more collateral, all of it protocol yield
    // the quote must not move: borrow() skims it away first
    assertApproxEqRel(account.borrowable(), before, 0.001e18);
  }

  function test_withdrawable_isExact() public {
    _depositSlis(1000 ether);

    // no debt: the whole principal is withdrawable
    assertEq(account.withdrawable(), account.principalBnb());

    uint256 borrowAmount = account.borrowable() / 2;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    uint256 quote = account.withdrawable();
    assertGt(quote, 0);
    assertLt(quote, account.principalBnb()); // debt now caps it below principal

    vm.prank(owner);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    account.withdraw(quote + 0.01 ether, owner);

    vm.prank(owner);
    account.withdraw(quote, owner);
    assertGt(SLISBNB.balanceOf(owner), 0);
  }

  function test_withdrawable_cappedByPrincipal() public {
    _depositSlis(1000 ether);
    _donate(100 ether);
    // yield never widens what the owner may withdraw
    assertEq(account.withdrawable(), account.principalBnb());
  }

  /* ----------------------------- init ----------------------------- */

  function test_initialize() public view {
    assertEq(address(account.MOOLAH()), address(MOOLAH));
    assertEq(address(account.PROVIDER()), address(PROVIDER));
    assertEq(account.TOKEN(), address(SLISBNB));
    assertEq(address(account.STAKE_MANAGER()), address(stakeManager));
    assertEq(Id.unwrap(account.marketId()), Id.unwrap(id));
    assertEq(account.treasury(), treasury);
    assertEq(account.minSkimBnb(), 0.001 ether);
    assertEq(account.principalBnb(), 0);
    assertTrue(account.isReceiver(owner));
    assertEq(account.getReceivers().length, 1);
    assertEq(account.getReceivers()[0], owner);
    assertTrue(account.hasRole(account.DEFAULT_ADMIN_ROLE(), TIMELOCK));
    assertTrue(account.hasRole(account.MANAGER(), manager));
    assertTrue(account.hasRole(account.PAUSER(), pauser));
    assertEq(account.OWNER(), owner);

    address minter = PROVIDER.slisBNBxMinter();
    if (minter != address(0)) {
      assertEq(ISlisBNBxMinter(minter).delegation(address(account)), owner);
    }
  }

  /// @dev the delegatee is set at init, not left to a later call — slisBNBx starts accruing with
  ///      the first deposit
  function test_initialize_delegateeIsMandatory() public {
    address minter = PROVIDER.slisBNBxMinter();
    assertTrue(minter != address(0));
    assertEq(ISlisBNBxMinter(minter).delegation(address(account)), owner);

    // slisBNBx actually lands on the delegatee once collateral is in
    _depositSlis(1000 ether);
    (uint256 userPart, ) = ISlisBNBxMinter(minter).userModuleBalance(address(account), address(PROVIDER));
    assertGt(userPart, 0);

    // a zero delegatee is rejected at init
    address[] memory r = new address[](1);
    r[0] = owner;
    YieldAccount impl = new YieldAccount(address(MOOLAH), address(PROVIDER), owner);
    vm.expectRevert(IYieldAccount.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(YieldAccount.initialize, (TIMELOCK, manager, pauser, params, treasury, 0.001 ether, address(0), r))
    );
  }

  /* ----------------------------- donations ----------------------------- */

  /// @dev a third party cannot reach the collateral side of Moolah directly: with a provider
  ///      registered, Moolah only accepts supplyCollateral from that provider
  function test_donation_moolahSupplyCollateralIsBlocked() public {
    deal(address(SLISBNB), donor, 10 ether);
    vm.startPrank(donor);
    SLISBNB.approve(address(MOOLAH), 10 ether);
    vm.expectRevert(bytes(ErrorsLib.NOT_PROVIDER));
    MOOLAH.supplyCollateral(params, 10 ether, address(account), "");
    vm.stopPrank();
  }

  /// @dev a donation through the provider is protocol yield, and `sync` is not what handles it —
  ///      `sync` only clamps principal when collateral UNITS drop. The skim collects it.
  function test_donation_viaProvider_syncChangesNothing() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();

    _donate(50 ether);
    uint256 claimable = account.claimableYield();
    assertGt(claimable, 0);

    // sync is a no-op here: nothing was seized
    account.sync();
    assertEq(account.principalBnb(), principal);
    assertEq(account.claimableYield(), claimable);

    // the skim is what moves it, and it goes to the treasury
    vm.prank(keeper);
    uint256 skimmed = account.skim();
    assertApproxEqAbs(skimmed, 50 ether, 2);
    assertEq(SLISBNB.balanceOf(treasury), skimmed);
    assertEq(account.principalBnb(), principal);
  }

  /// @dev MOOLAH.supply is the LEND side: it hands the account supplyShares in lisUSD, which is not
  ///      part of the account's accounting at all. `sync` cannot see it and the account cannot
  ///      withdraw it — a stray supply position is stuck until an upgrade.
  function test_donation_moolahSupplyIsInvisibleAndStuck() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();
    uint256 coll = account.collateral();
    uint256 claimable = account.claimableYield();

    deal(address(LISUSD), donor, 1000 ether);
    vm.startPrank(donor);
    LISUSD.approve(address(MOOLAH), 1000 ether);
    MOOLAH.supply(params, 1000 ether, 0, address(account), "");
    vm.stopPrank();

    // the account now holds a lending position
    assertGt(MOOLAH.position(id, address(account)).supplyShares, 0);

    // none of the account's accounting moved, and sync does not change that
    account.sync();
    assertEq(account.principalBnb(), principal);
    assertEq(account.collateral(), coll);
    assertEq(account.trackedCollateral(), coll);
    assertEq(account.claimableYield(), claimable);
  }

  /* ----------------------------- deposits ----------------------------- */

  function test_depositSlisBnb() public {
    uint256 amount = 100 ether;
    uint256 bnbValue = _depositSlis(amount);

    assertEq(account.collateral(), amount);
    assertEq(account.principalBnb(), bnbValue);
    assertEq(account.trackedCollateral(), amount);
    assertEq(PROVIDER.userTotalDeposit(address(account)), amount);
    // exchange rate >= 1, so BNB value is at least the slisBNB amount
    assertGe(bnbValue, amount);
  }

  function test_depositBnb() public {
    deal(owner, 100 ether);
    vm.prank(owner);
    uint256 slisAmount = account.depositBnb{ value: 50 ether }();

    assertGt(slisAmount, 0);
    assertEq(account.collateral(), slisAmount);
    // principal is credited with the value of the slisBNB actually received
    assertApproxEqAbs(account.principalBnb(), 50 ether, 1e9);
    assertLe(account.principalBnb(), 50 ether + 1);
  }

  function test_deposit_zeroReverts() public {
    vm.expectRevert(IYieldAccount.ZeroAmount.selector);
    account.depositSlisBnb(0);
    vm.expectRevert(IYieldAccount.ZeroAmount.selector);
    account.depositBnb();
  }

  /* ----------------------------- skim ----------------------------- */

  function test_skim_collectsExcessToTreasury() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();

    uint256 donation = 50 ether;
    _donate(donation);
    assertEq(account.collateral(), 1050 ether);

    // anyone can skim
    vm.prank(keeper);
    uint256 skimmed = account.skim();

    // the whole donation (value above principal) goes to the treasury, +-rounding in owner's favor
    assertApproxEqAbs(skimmed, donation, 2);
    assertLe(skimmed, donation);
    assertEq(SLISBNB.balanceOf(treasury), skimmed);
    // position back to principal value; principal itself untouched
    assertEq(account.principalBnb(), principal);
    assertApproxEqAbs(stakeManager.convertSnBnbToBnb(account.collateral()), principal, 1e9);
    assertGe(stakeManager.convertSnBnbToBnb(account.collateral()), principal);
  }

  function test_skim_nothingReverts() public {
    _depositSlis(100 ether);
    vm.expectRevert(IYieldAccount.NothingToSkim.selector);
    vm.prank(keeper);
    account.skim();
  }

  function test_skim_belowMinReverts() public {
    _depositSlis(1000 ether);
    // donate less than minSkimBnb (0.001 BNB)
    _donate(0.0001 ether);
    vm.expectRevert(IYieldAccount.NothingToSkim.selector);
    vm.prank(keeper);
    account.skim();
  }

  function test_skim_healthCapped() public {
    _depositSlis(1000 ether);
    // borrow right at the principal-based cap
    uint256 maxBorrow = _maxBorrow();
    vm.prank(owner);
    account.borrow(maxBorrow - 1e18, owner);

    // yield arrives; a full skim would now break health, so the skim must self-cap
    _donate(100 ether);
    vm.prank(keeper);
    uint256 skimmed = account.skim();
    assertGt(skimmed, 0);
    assertLt(skimmed, 100 ether);
    // position stays healthy after the capped skim
    assertTrue(IHealthView(address(MOOLAH)).isHealthy(params, id, address(account)));
  }

  /* ----------------------------- borrow ----------------------------- */

  function test_borrow_happy() public {
    _depositSlis(1000 ether);
    uint256 amount = 10_000 ether; // lisUSD

    vm.prank(owner);
    account.borrow(amount, owner);

    assertEq(LISUSD.balanceOf(owner), amount);
    assertGt(account.debt(), 0);
  }

  function test_borrow_cappedByPrincipal() public {
    _depositSlis(1000 ether);
    uint256 maxBorrow = _maxBorrow();

    vm.prank(owner);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    account.borrow((maxBorrow * 101) / 100, owner);

    vm.prank(owner);
    account.borrow((maxBorrow * 99) / 100, owner);
  }

  function test_borrow_skimsYieldFirst() public {
    _depositSlis(1000 ether);
    uint256 maxBorrow = _maxBorrow();

    // 20% extra collateral value arrives as yield
    _donate(200 ether);

    // must fail: the borrow path skims first, so the donation never lifts the cap
    vm.prank(owner);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    account.borrow((maxBorrow * 110) / 100, owner);

    vm.prank(owner);
    account.borrow((maxBorrow * 99) / 100, owner);

    // the successful borrow's embedded skim moved the yield to the treasury, not the position
    assertApproxEqAbs(SLISBNB.balanceOf(treasury), 200 ether, 2);
  }

  function test_borrow_accessControl() public {
    _depositSlis(1000 ether);

    vm.prank(stranger);
    vm.expectRevert();
    account.borrow(1000 ether, stranger);

    vm.prank(owner);
    vm.expectRevert(IYieldAccount.NotReceiver.selector);
    account.borrow(1000 ether, stranger);
  }

  /* ----------------------------- withdraw ----------------------------- */

  function test_withdraw_partial() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();
    uint256 bnbOut = principal / 4;
    uint256 expectedSlis = stakeManager.convertBnbToSnBnb(bnbOut);

    vm.prank(owner);
    account.withdraw(bnbOut, owner);

    assertEq(SLISBNB.balanceOf(owner), expectedSlis);
    assertEq(account.principalBnb(), principal - bnbOut);
    assertEq(account.collateral(), 1000 ether - expectedSlis);
  }

  function test_withdraw_all_afterYield() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();
    _donate(50 ether);

    vm.prank(owner);
    account.withdraw(type(uint256).max, owner);

    // owner got principal value back (never the yield), treasury got the rest
    uint256 ownerValue = stakeManager.convertSnBnbToBnb(SLISBNB.balanceOf(owner));
    assertApproxEqAbs(ownerValue, principal, 1e9);
    assertLe(ownerValue, principal + 1);
    assertApproxEqAbs(SLISBNB.balanceOf(treasury), 50 ether, 2);
    assertEq(account.principalBnb(), 0);
    assertEq(account.collateral(), 0);
  }

  function test_withdraw_moreThanPrincipalReverts() public {
    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();

    vm.prank(owner);
    vm.expectRevert(IYieldAccount.ExceedsPrincipal.selector);
    account.withdraw(principal + 1 ether, owner);
  }

  /// @dev the embedded skim skips yield below minSkimBnb; the owner still cannot walk out with it
  function test_withdraw_cannotTakeSubMinSkimYield() public {
    vm.prank(manager);
    account.setMinSkimBnb(10 ether); // well above the donation below

    _depositSlis(1000 ether);
    uint256 principal = account.principalBnb();
    _donate(1 ether); // unskimmable yield

    // the partial path is capped at principal
    vm.prank(owner);
    vm.expectRevert(IYieldAccount.ExceedsPrincipal.selector);
    account.withdraw(principal + 0.5 ether, owner);

    // and the full exit force-skims it to the treasury rather than paying it out
    vm.prank(owner);
    account.withdraw(type(uint256).max, owner);

    assertApproxEqAbs(SLISBNB.balanceOf(treasury), 1 ether, 2);
    uint256 ownerValue = stakeManager.convertSnBnbToBnb(SLISBNB.balanceOf(owner));
    assertApproxEqAbs(ownerValue, principal, 1e9);
    assertLe(ownerValue, principal + 1);
  }

  function test_withdraw_healthEnforcedWithDebt() public {
    _depositSlis(1000 ether);
    // _maxBorrow() makes an external call — evaluate before the prank so it is not consumed
    uint256 borrowAmount = _maxBorrow() / 2;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    // withdrawing most of the collateral would break health
    uint256 principal = account.principalBnb();
    vm.prank(owner);
    vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
    account.withdraw((principal * 90) / 100, owner);
  }

  function test_withdraw_accessControl() public {
    _depositSlis(100 ether);

    vm.prank(stranger);
    vm.expectRevert();
    account.withdraw(1 ether, stranger);

    vm.prank(owner);
    vm.expectRevert(IYieldAccount.NotReceiver.selector);
    account.withdraw(1 ether, stranger);
  }

  /* ----------------------------- repay ----------------------------- */

  function test_repay_partial_and_full() public {
    _depositSlis(1000 ether);
    uint256 borrowed = 50_000 ether;
    vm.prank(owner);
    account.borrow(borrowed, owner);

    // partial repay by a third party
    deal(address(LISUSD), keeper, 20_000 ether);
    vm.startPrank(keeper);
    LISUSD.approve(address(account), 20_000 ether);
    account.repay(20_000 ether);
    vm.stopPrank();
    assertApproxEqAbs(account.debt(), 30_000 ether, 1e6);

    // full repay by owner via the max sentinel
    deal(address(LISUSD), owner, 40_000 ether);
    vm.startPrank(owner);
    LISUSD.approve(address(account), 40_000 ether);
    account.repay(type(uint256).max);
    vm.stopPrank();

    assertEq(account.debt(), 0);
    assertEq(MOOLAH.position(id, address(account)).borrowShares, 0);
    assertEq(LISUSD.balanceOf(address(account)), 0);
  }

  /// @dev loan tokens sent here by mistake must stay put. `repay` refunds only the unused part of
  ///      what the caller pulled in, so a 1 wei repay cannot walk off with someone else's tokens.
  function test_repay_doesNotSweepStrayLoanToken() public {
    _depositSlis(1000 ether);
    vm.prank(owner);
    account.borrow(50_000 ether, owner);

    // someone transfers loan tokens straight to the account instead of calling repay
    uint256 stray = 1000 ether;
    deal(address(LISUSD), donor, stray);
    vm.prank(donor);
    LISUSD.transfer(address(account), stray);
    assertEq(LISUSD.balanceOf(address(account)), stray);

    // the assets path: an attacker triggers the smallest repay there is
    address attacker = makeAddr("attacker");
    deal(address(LISUSD), attacker, 1);
    vm.startPrank(attacker);
    LISUSD.approve(address(account), 1);
    account.repay(1);
    vm.stopPrank();

    assertEq(LISUSD.balanceOf(attacker), 0, "attacker drained the stray balance");
    assertEq(LISUSD.balanceOf(address(account)), stray, "stray balance moved");

    // the shares path, which is the one that actually has rounding to refund
    deal(address(LISUSD), owner, 60_000 ether);
    vm.startPrank(owner);
    LISUSD.approve(address(account), 60_000 ether);
    account.repay(type(uint256).max);
    vm.stopPrank();

    assertEq(account.debt(), 0);
    assertEq(MOOLAH.position(id, address(account)).borrowShares, 0);
    assertEq(LISUSD.balanceOf(address(account)), stray, "max repay swept the stray balance");
  }

  /// @dev anyone can repay this account's debt straight through Moolah, without touching the
  ///      account: Moolah gates repay only when the market has a broker, and this one has none
  function test_repay_byThirdParty_directlyOnMoolah() public {
    _depositSlis(1000 ether);
    uint256 borrowAmount = account.borrowable() / 2;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    uint256 debtBefore = account.debt();
    uint256 principalBefore = account.principalBnb();
    uint256 collBefore = account.collateral();
    uint256 quoteBefore = account.borrowable();

    uint256 amount = debtBefore / 4;
    deal(address(LISUSD), stranger, amount);
    vm.startPrank(stranger);
    LISUSD.approve(address(MOOLAH), amount);
    MOOLAH.repay(params, amount, 0, address(account), "");
    vm.stopPrank();

    assertApproxEqAbs(account.debt(), debtBefore - amount, 1e6);
    // the account's own accounting does not track debt, so nothing drifts
    assertEq(account.principalBnb(), principalBefore);
    assertEq(account.collateral(), collBefore);
    assertEq(account.trackedCollateral(), collBefore);
    // the freed room shows up in the quote
    assertGt(account.borrowable(), quoteBefore);
  }

  /* ----------------------------- liquidation / sync ----------------------------- */

  function test_liquidation_thenSyncClampsPrincipal() public {
    _depositSlis(1000 ether);
    uint256 principalBefore = account.principalBnb();
    uint256 borrowAmount = (_maxBorrow() * 99) / 100;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    // slisBNB price drops 10% -> position under water
    uint256 slisPrice = IOracleView(MULTI_ORACLE).peek(address(SLISBNB));
    vm.mockCall(
      MULTI_ORACLE,
      abi.encodeWithSelector(IOracleView.peek.selector, address(SLISBNB)),
      abi.encode((slisPrice * 90) / 100)
    );
    assertFalse(IHealthView(address(MOOLAH)).isHealthy(params, id, address(account)));

    // make this contract a liquidator if the market restricts liquidations
    if (!MOOLAH.isLiquidationWhitelist(id, address(this))) {
      vm.prank(TIMELOCK);
      IAccessControl(address(MOOLAH)).grantRole(keccak256("MANAGER"), address(this));
      Id[] memory ids = new Id[](1);
      ids[0] = id;
      address[][] memory accounts = new address[][](1);
      accounts[0] = new address[](1);
      accounts[0][0] = address(this);
      MOOLAH.batchToggleLiquidationWhitelist(ids, accounts, true);
    }

    uint128 shares = MOOLAH.position(id, address(account)).borrowShares;
    deal(address(LISUSD), address(this), 1_000_000 ether);
    LISUSD.approve(address(MOOLAH), type(uint256).max);
    MOOLAH.liquidate(params, address(account), 0, shares / 2, "");

    uint256 collAfter = account.collateral();
    assertLt(collAfter, 1000 ether);

    uint256 seizedValue = stakeManager.convertSnBnbToBnb(1000 ether - collAfter);
    account.sync();
    // principal is charged the seized VALUE, not clamped to the remaining value
    assertEq(account.principalBnb(), principalBefore - seizedValue);
    assertLt(account.principalBnb(), principalBefore);
    // no phantom yield after the charge
    (uint256 skimAmount, ) = account.skimmable();
    assertEq(skimAmount, 0);
  }

  /// @dev principal takes the liquidation hit; the treasury's yield claim survives
  function test_liquidation_doesNotConsumeTreasuryYield() public {
    _depositSlis(1000 ether);
    uint256 principalBefore = account.principalBnb();
    uint256 borrowAmount = (_maxBorrow() * 99) / 100;
    vm.prank(owner);
    account.borrow(borrowAmount, owner);

    // production yield is exchange-rate growth, which leaves collateral UNITS untouched; a
    // donation adds units, so sync() is what makes the two equivalent here
    _donate(50 ether);
    account.sync();

    uint256 slisPrice = IOracleView(MULTI_ORACLE).peek(address(SLISBNB));
    vm.mockCall(
      MULTI_ORACLE,
      abi.encodeWithSelector(IOracleView.peek.selector, address(SLISBNB)),
      abi.encode((slisPrice * 80) / 100)
    );

    if (!MOOLAH.isLiquidationWhitelist(id, address(this))) {
      vm.prank(TIMELOCK);
      IAccessControl(address(MOOLAH)).grantRole(keccak256("MANAGER"), address(this));
      Id[] memory ids = new Id[](1);
      ids[0] = id;
      address[][] memory accounts = new address[][](1);
      accounts[0] = new address[](1);
      accounts[0][0] = address(this);
      MOOLAH.batchToggleLiquidationWhitelist(ids, accounts, true);
    }

    uint256 collBefore = account.collateral();
    uint128 shares = MOOLAH.position(id, address(account)).borrowShares;
    deal(address(LISUSD), address(this), 5_000_000 ether);
    LISUSD.approve(address(MOOLAH), type(uint256).max);
    MOOLAH.liquidate(params, address(account), 0, shares / 4, "");

    uint256 seizedValue = stakeManager.convertSnBnbToBnb(collBefore - account.collateral());
    account.sync();

    assertEq(account.principalBnb(), principalBefore - seizedValue);
    // still owed to the treasury. Asserted on the accounting identity, not skimmable(), which is
    // health-capped while debt remains at the depressed price.
    uint256 owedToTreasury = account.collateralValueBnb() - account.principalBnb();
    assertApproxEqAbs(owedToTreasury, stakeManager.convertSnBnbToBnb(50 ether), 1e12);
  }

  /* ----------------------------- migrator authorization ----------------------------- */

  function test_migratorAuthorization() public {
    // no migrator configured yet
    vm.prank(owner);
    vm.expectRevert(IYieldAccount.NotMigrator.selector);
    account.setMigratorAuthorization(migrator, true);

    vm.prank(TIMELOCK);
    account.setMigrator(migrator);

    vm.prank(owner);
    account.setMigratorAuthorization(migrator, true);
    assertTrue(MOOLAH.isAuthorized(address(account), migrator));

    vm.prank(owner);
    account.setMigratorAuthorization(migrator, false);
    assertFalse(MOOLAH.isAuthorized(address(account), migrator));

    // replacing the migrator revokes a standing authorization
    vm.prank(owner);
    account.setMigratorAuthorization(migrator, true);
    address migrator2 = makeAddr("migrator2");
    vm.prank(TIMELOCK);
    account.setMigrator(migrator2);
    assertFalse(MOOLAH.isAuthorized(address(account), migrator));

    // only OWNER can authorize
    vm.prank(stranger);
    vm.expectRevert();
    account.setMigratorAuthorization(migrator2, true);

    vm.prank(owner);
    vm.expectRevert(IYieldAccount.ZeroAddress.selector);
    account.setMigratorAuthorization(address(0), true);
  }

  /// @dev the OWNER names the migrator it approves, so a swap front-running it reverts
  function test_migratorAuthorization_pinnedAgainstSwap() public {
    vm.prank(TIMELOCK);
    account.setMigrator(migrator);

    address evil = makeAddr("evilMigrator");
    // MANAGER cannot swap the address at all since the split
    vm.prank(manager);
    vm.expectRevert();
    account.setMigrator(evil);

    // and a swap by the TimeLock does not make the owner's pinned approval land on the replacement
    vm.prank(TIMELOCK);
    account.setMigrator(evil);

    vm.prank(owner);
    vm.expectRevert(IYieldAccount.NotMigrator.selector);
    account.setMigratorAuthorization(migrator, true);

    assertFalse(MOOLAH.isAuthorized(address(account), migrator));
    assertFalse(MOOLAH.isAuthorized(address(account), evil));
  }

  /* ----------------------------- provider registration ----------------------------- */

  function test_initialize_revertsWhenProviderNotRegistered() public {
    // the market exists but has no provider registered for slisBNB
    vm.mockCall(
      address(MOOLAH),
      abi.encodeWithSignature("providers(bytes32,address)", Id.unwrap(id), address(SLISBNB)),
      abi.encode(address(0))
    );

    address[] memory receivers = new address[](1);
    receivers[0] = owner;
    YieldAccount impl = new YieldAccount(address(MOOLAH), address(PROVIDER), owner);
    vm.expectRevert(IYieldAccount.ProviderNotRegistered.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(
        YieldAccount.initialize,
        (TIMELOCK, manager, pauser, params, treasury, 0.001 ether, owner, receivers)
      )
    );
  }

  function test_deposit_revertsWhenProviderUnregistered() public {
    _depositSlis(10 ether);

    // governance unregisters the provider for this market
    vm.prank(TIMELOCK);
    IAccessControl(address(MOOLAH)).grantRole(keccak256("MANAGER"), address(this));
    MOOLAH.setProvider(marketId(), address(PROVIDER), false);

    deal(address(SLISBNB), owner, 1 ether);
    vm.startPrank(owner);
    SLISBNB.approve(address(account), 1 ether);
    vm.expectRevert(IYieldAccount.ProviderNotRegistered.selector);
    account.depositSlisBnb(1 ether);
    vm.stopPrank();
  }

  function marketId() internal view returns (Id) {
    return id;
  }

  /* ----------------------------- slisBNBx delegation ----------------------------- */

  function test_delegateSlisBNBx() public {
    address minter = PROVIDER.slisBNBxMinter();
    vm.skip(minter == address(0));

    address newDelegatee = makeAddr("newDelegatee");
    vm.prank(owner);
    account.delegateSlisBNBx(newDelegatee);
    assertEq(ISlisBNBxMinter(minter).delegation(address(account)), newDelegatee);

    vm.prank(stranger);
    vm.expectRevert();
    account.delegateSlisBNBx(stranger);
  }

  /* ----------------------------- pause & config ----------------------------- */

  function test_pause_gates() public {
    _depositSlis(1000 ether);
    vm.prank(owner);
    account.borrow(10_000 ether, owner);

    vm.prank(pauser);
    account.pause();

    deal(address(SLISBNB), owner, 1 ether);
    vm.startPrank(owner);
    SLISBNB.approve(address(account), 1 ether);
    vm.expectRevert();
    account.depositSlisBnb(1 ether);
    vm.expectRevert();
    account.borrow(1 ether, owner);
    vm.expectRevert();
    account.withdraw(1 ether, owner);
    vm.stopPrank();
    vm.expectRevert();
    account.skim();

    // repay stays open while paused — debt must always be reducible
    deal(address(LISUSD), keeper, 5_000 ether);
    vm.startPrank(keeper);
    LISUSD.approve(address(account), 5_000 ether);
    account.repay(5_000 ether);
    vm.stopPrank();

    vm.prank(manager);
    account.unpause();
    vm.startPrank(owner);
    SLISBNB.approve(address(account), 1 ether);
    account.depositSlisBnb(1 ether);
    vm.stopPrank();
  }

  function test_managerConfig_accessControl() public {
    vm.startPrank(stranger);
    vm.expectRevert();
    account.setTreasury(stranger);
    vm.expectRevert();
    account.setMinSkimBnb(1);
    vm.expectRevert();
    account.setMigrator(stranger);
    vm.expectRevert();
    account.addReceiver(stranger);
    vm.expectRevert();
    account.removeReceiver(owner);
    vm.stopPrank();

    vm.startPrank(manager);
    account.setTreasury(makeAddr("treasury2"));
    account.setMinSkimBnb(0.01 ether);
    account.addReceiver(stranger);
    assertTrue(account.isReceiver(stranger));
    assertEq(account.getReceivers().length, 2);
    account.removeReceiver(stranger);
    assertFalse(account.isReceiver(stranger));
    assertEq(account.getReceivers().length, 1);
    // the list must never empty out, or borrow and withdraw revert on every call
    vm.expectRevert(IYieldAccount.NoReceiver.selector);
    account.removeReceiver(owner);
    // migrator is DEFAULT_ADMIN's, not MANAGER's
    vm.expectRevert();
    account.setMigrator(migrator);
    vm.stopPrank();
  }

  /// @dev MANAGER can switch authorization on but not choose the address, so one key cannot route
  ///      the principal to itself
  function test_permissionSplit_managerCannotPickMigrator() public {
    _depositSlis(100 ether);

    address evil = makeAddr("evilMigrator");
    vm.prank(manager);
    vm.expectRevert();
    account.setMigrator(evil);

    // MANAGER can only authorize what the TimeLock chose
    vm.prank(TIMELOCK);
    account.setMigrator(migrator);
    vm.prank(manager);
    vm.expectRevert(IYieldAccount.NotMigrator.selector);
    account.setMigratorAuthorization(evil, true);
    assertFalse(MOOLAH.isAuthorized(address(account), evil));

    vm.prank(manager);
    account.setMigratorAuthorization(migrator, true);
    assertTrue(MOOLAH.isAuthorized(address(account), migrator));

    // and a stranger holds neither role
    vm.prank(stranger);
    vm.expectRevert(IYieldAccount.NotAuthorized.selector);
    account.setMigratorAuthorization(migrator, false);
  }
}

interface IOracleView {
  function peek(address token) external view returns (uint256);
}

interface IHealthView {
  function isHealthy(MarketParams memory marketParams, Id id, address borrower) external view returns (bool);
}

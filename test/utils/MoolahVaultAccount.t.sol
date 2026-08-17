// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { ERC20Mock } from "moolah-vault/mocks/ERC20Mock.sol";
import { MoolahVaultAccount } from "../../src/utils/MoolahVaultAccount.sol";
import { MockYieldVault } from "./mocks/MockYieldVault.sol";

contract MoolahVaultAccountTest is Test {
  MoolahVaultAccount public impl;
  MoolahVaultAccount public manager;
  MockYieldVault public vaultMock;
  ERC20Mock public token;

  address admin = makeAddr("admin");
  address managerSafe = makeAddr("managerSafe");
  address bot = makeAddr("bot");
  address pauser = makeAddr("pauser");
  address lsr = makeAddr("lsr");
  address buyback = makeAddr("buyback");
  address stranger = makeAddr("stranger");

  uint256 constant PRINCIPAL = 1_000_000 ether;
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");
  bytes32 constant BOT_ROLE = keccak256("BOT");
  bytes32 constant PAUSER_ROLE = keccak256("PAUSER");

  function setUp() public {
    token = new ERC20Mock("Mock lisUSD", "mLisUSD");
    vaultMock = new MockYieldVault(IERC20(address(token)));

    // Deployed once, in setUp, and reused by _deploy. Deploying the implementation inside _deploy
    // would make vm.expectRevert consume the implementation's successful CREATE instead of the
    // proxy's reverting one, so the zero-address tests would pass for the wrong reason.
    impl = new MoolahVaultAccount();

    manager = _deploy(admin, managerSafe, bot, pauser, address(vaultMock), managerSafe, PRINCIPAL, _twoRecipients());

    // give the manager a position worth exactly PRINCIPAL
    token.mint(address(this), PRINCIPAL);
    token.approve(address(vaultMock), PRINCIPAL);
    vaultMock.deposit(PRINCIPAL, address(manager));
  }

  function _deploy(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address _vault,
    address _principalOwner,
    uint256 _principal,
    address[] memory _recipients
  ) internal returns (MoolahVaultAccount) {
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(
        MoolahVaultAccount.initialize,
        (_admin, _manager, _bot, _pauser, _vault, _principalOwner, _principal, _recipients)
      )
    );
    return MoolahVaultAccount(address(proxy));
  }

  function _twoRecipients() internal view returns (address[] memory r) {
    r = new address[](2);
    r[0] = lsr;
    r[1] = buyback;
  }

  function _oneRecipient(address to) internal pure returns (address[] memory r) {
    r = new address[](1);
    r[0] = to;
  }

  // ----------------------------------------------------------------- initialize

  function test_initialize_setsState() public view {
    assertEq(address(manager.vault()), address(vaultMock));
    assertEq(address(manager.asset()), address(token));
    assertEq(manager.principalOwner(), managerSafe);
    assertEq(manager.principal(), PRINCIPAL);
    assertTrue(manager.isYieldRecipient(lsr));
    assertTrue(manager.isYieldRecipient(buyback));
    assertFalse(manager.isYieldRecipient(stranger));
  }

  function test_initialize_grantsRoles() public view {
    assertTrue(manager.hasRole(bytes32(0), admin));
    assertTrue(manager.hasRole(MANAGER_ROLE, managerSafe));
    assertTrue(manager.hasRole(BOT_ROLE, bot));
    assertTrue(manager.hasRole(PAUSER_ROLE, pauser));
    // the deployer holds nothing — initialize grants the final holders directly
    assertFalse(manager.hasRole(bytes32(0), address(this)));
    assertFalse(manager.hasRole(MANAGER_ROLE, address(this)));
  }

  function test_initialize_setsBotRoleAdminToManager() public {
    assertEq(manager.getRoleAdmin(BOT_ROLE), MANAGER_ROLE);

    address newBot = makeAddr("newBot");
    vm.prank(managerSafe);
    manager.grantRole(BOT_ROLE, newBot);
    assertTrue(manager.hasRole(BOT_ROLE, newBot));
  }

  function test_initialize_revertsOnZeroAddress() public {
    address[] memory r = _twoRecipients();
    address[6] memory args = [admin, managerSafe, bot, pauser, address(vaultMock), managerSafe];

    for (uint256 i = 0; i < 6; ++i) {
      address[6] memory a = args;
      a[i] = address(0);
      vm.expectRevert(MoolahVaultAccount.ZeroAddress.selector);
      _deploy(a[0], a[1], a[2], a[3], a[4], a[5], PRINCIPAL, r);
    }
  }

  function test_initialize_revertsOnEmptyYieldRecipients() public {
    address[] memory empty = new address[](0);
    vm.expectRevert(MoolahVaultAccount.NoYieldRecipient.selector);
    _deploy(admin, managerSafe, bot, pauser, address(vaultMock), managerSafe, PRINCIPAL, empty);
  }

  function test_initialize_revertsOnZeroYieldRecipient() public {
    vm.expectRevert(MoolahVaultAccount.ZeroAddress.selector);
    _deploy(admin, managerSafe, bot, pauser, address(vaultMock), managerSafe, PRINCIPAL, _oneRecipient(address(0)));
  }

  function test_initialize_revertsOnDuplicateYieldRecipient() public {
    address[] memory dup = new address[](2);
    dup[0] = lsr;
    dup[1] = lsr;
    vm.expectRevert(MoolahVaultAccount.DuplicateRecipient.selector);
    _deploy(admin, managerSafe, bot, pauser, address(vaultMock), managerSafe, PRINCIPAL, dup);
  }

  function test_reinitialize_reverts() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    manager.initialize(admin, managerSafe, bot, pauser, address(vaultMock), managerSafe, PRINCIPAL, _twoRecipients());
  }

  // ------------------------------------------------------------------ recipients

  function test_addYieldRecipient() public {
    vm.prank(managerSafe);
    manager.addYieldRecipient(stranger);

    assertTrue(manager.isYieldRecipient(stranger));
    address[] memory list = manager.getYieldRecipients();
    assertEq(list.length, 3);
    assertEq(list[2], stranger);
  }

  function test_addYieldRecipient_revertsOnDuplicate() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.DuplicateRecipient.selector);
    manager.addYieldRecipient(lsr);
  }

  function test_addYieldRecipient_revertsOnZero() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ZeroAddress.selector);
    manager.addYieldRecipient(address(0));
  }

  function test_addYieldRecipient_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.addYieldRecipient(stranger);
  }

  function test_removeYieldRecipient_swapAndPop() public {
    // remove the FIRST of two, so the swap-and-pop actually moves an element
    vm.prank(managerSafe);
    manager.removeYieldRecipient(lsr);

    assertFalse(manager.isYieldRecipient(lsr));
    assertTrue(manager.isYieldRecipient(buyback));
    address[] memory list = manager.getYieldRecipients();
    assertEq(list.length, 1);
    assertEq(list[0], buyback);
  }

  function test_removeYieldRecipient_revertsIfAbsent() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.RecipientNotFound.selector);
    manager.removeYieldRecipient(stranger);
  }

  /// @dev initialize forbids an empty whitelist, so the runtime must not be able to reach one — an
  ///      empty list would make every claimYield call revert until MANAGER added an address back.
  function test_removeYieldRecipient_revertsOnLast() public {
    vm.startPrank(managerSafe);
    manager.removeYieldRecipient(lsr);
    vm.expectRevert(MoolahVaultAccount.NoYieldRecipient.selector);
    manager.removeYieldRecipient(buyback);
    vm.stopPrank();
  }

  function test_removeYieldRecipient_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.removeYieldRecipient(lsr);
  }

  // ------------------------------------------------------------------ principalOwner

  function test_setPrincipalOwner() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(admin);
    manager.setPrincipalOwner(newOwner);
    assertEq(manager.principalOwner(), newOwner);
  }

  /// @dev MANAGER must NOT be able to redirect principal.
  function test_setPrincipalOwner_onlyAdmin() public {
    vm.prank(managerSafe);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, managerSafe, bytes32(0))
    );
    manager.setPrincipalOwner(stranger);
  }

  function test_setPrincipalOwner_revertsOnZeroAndSame() public {
    vm.startPrank(admin);
    vm.expectRevert(MoolahVaultAccount.ZeroAddress.selector);
    manager.setPrincipalOwner(address(0));
    vm.expectRevert(MoolahVaultAccount.AlreadySet.selector);
    manager.setPrincipalOwner(managerSafe);
    vm.stopPrank();
  }

  // ------------------------------------------------------------------ pause / upgrade

  function test_pause_onlyPauser_unpause_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE)
    );
    manager.pause();

    vm.prank(pauser);
    manager.pause();
    assertTrue(manager.paused());

    // the pauser cannot unpause — asymmetric by design
    vm.prank(pauser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, MANAGER_ROLE)
    );
    manager.unpause();

    vm.prank(managerSafe);
    manager.unpause();
    assertFalse(manager.paused());
  }

  function test_upgrade_onlyAdmin() public {
    MoolahVaultAccount newImpl = new MoolahVaultAccount();

    vm.prank(managerSafe);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, managerSafe, bytes32(0))
    );
    manager.upgradeToAndCall(address(newImpl), "");

    vm.prank(admin);
    manager.upgradeToAndCall(address(newImpl), "");
    assertEq(manager.principal(), PRINCIPAL); // state survived
  }
  // ------------------------------------------------------------------ views

  function test_totalAssets_matchesConvertToAssets() public view {
    assertEq(manager.totalAssets(), vaultMock.convertToAssets(vaultMock.balanceOf(address(manager))));
    assertEq(manager.totalAssets(), PRINCIPAL);
  }

  function test_claimableYield_zeroAtPrincipal() public view {
    assertEq(manager.claimableYield(), 0);
  }

  function test_claimableYield_afterAccrue() public {
    vaultMock.accrue(1_000 ether);
    // the manager holds every share, so the whole accrual is its surplus
    assertEq(manager.claimableYield(), 1_000 ether);
    assertEq(manager.totalAssets(), PRINCIPAL + 1_000 ether);
  }

  /// @dev C1: NAV is not monotonic. claimableYield must clamp at 0 and resume unaided.
  function test_claimableYield_clampsAfterLoss_andRecovers() public {
    vaultMock.accrue(1_000 ether);
    assertEq(manager.claimableYield(), 1_000 ether);

    vaultMock.loss(3_000 ether); // NAV now 2_000 below principal
    assertLt(manager.totalAssets(), manager.principal());
    assertEq(manager.claimableYield(), 0);

    vaultMock.accrue(2_500 ether); // back above principal
    assertEq(manager.claimableYield(), 500 ether);
  }

  function test_previewClaim_clampsToWithdrawable() public {
    vaultMock.accrue(1_000 ether);

    (uint256 claimable, uint256 withdrawable, uint256 claimableNow) = manager.previewClaim();
    assertEq(claimable, 1_000 ether);
    assertEq(withdrawable, vaultMock.maxWithdraw(address(manager)));
    assertEq(claimableNow, 1_000 ether);

    vaultMock.setLiquidity(400 ether);
    (claimable, withdrawable, claimableNow) = manager.previewClaim();
    assertEq(claimable, 1_000 ether); // unchanged — this is the accounting figure
    assertEq(withdrawable, 400 ether);
    assertEq(claimableNow, 400 ether); // clamped — this is what a claim can actually take
  }

  function test_getYieldRecipients_returnsSeeded() public view {
    address[] memory list = manager.getYieldRecipients();
    assertEq(list.length, 2);
    assertEq(list[0], lsr);
    assertEq(list[1], buyback);
  }
  // ------------------------------------------------------------------ principal

  function _fundManagerSafe(uint256 amount) internal {
    token.mint(managerSafe, amount);
    vm.prank(managerSafe);
    token.approve(address(manager), amount);
  }

  function test_depositPrincipal_increasesPrincipalAndPosition() public {
    _fundManagerSafe(500 ether);

    vm.prank(managerSafe);
    manager.depositPrincipal(500 ether);

    assertEq(manager.principal(), PRINCIPAL + 500 ether);
    assertEq(manager.totalAssets(), PRINCIPAL + 500 ether);
    assertEq(token.balanceOf(managerSafe), 0);
    assertEq(token.balanceOf(address(manager)), 0); // nothing left behind
  }

  /// @dev deposit mints floor shares while principal takes the full nominal, so the rounding always
  ///      goes against claimable — it can never be used to over-harvest.
  function test_depositPrincipal_roundingIsConservative() public {
    vaultMock.accrue(333 ether); // share price now above 1.0
    uint256 claimableBefore = manager.claimableYield();

    _fundManagerSafe(777 ether);
    vm.prank(managerSafe);
    manager.depositPrincipal(777 ether);

    assertLe(manager.claimableYield(), claimableBefore);
  }

  /// @dev a deposit too small to mint a share must revert, not raise principal for free.
  function test_depositPrincipal_revertsOnZeroShares() public {
    vaultMock.accrue(PRINCIPAL); // share price now 2.0, so 1 wei of assets mints 0 shares
    _fundManagerSafe(1);

    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ZeroShares.selector);
    manager.depositPrincipal(1);
  }

  function test_depositPrincipal_revertsOnZero() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ZeroAmount.selector);
    manager.depositPrincipal(0);
  }

  function test_depositPrincipal_onlyManager() public {
    token.mint(stranger, 1 ether);
    vm.startPrank(stranger);
    token.approve(address(manager), 1 ether);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.depositPrincipal(1 ether);
    vm.stopPrank();
  }

  function test_depositPrincipal_revertsWhenNotWhitelisted() public {
    vaultMock.setWhitelistEnabled(true); // the manager is not on the list
    _fundManagerSafe(200 ether);

    vm.prank(managerSafe);
    vm.expectRevert("NotWhiteList");
    manager.depositPrincipal(100 ether);

    vaultMock.setWhiteList(address(manager), true);
    vm.prank(managerSafe);
    manager.depositPrincipal(100 ether);
    assertEq(manager.principal(), PRINCIPAL + 100 ether);
  }

  function test_depositPrincipal_revertsWhenPaused() public {
    _fundManagerSafe(100 ether);
    vm.prank(pauser);
    manager.pause();

    vm.prank(managerSafe);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    manager.depositPrincipal(100 ether);
  }

  function test_withdrawPrincipal_sendsToPrincipalOwner() public {
    vm.prank(managerSafe);
    manager.withdrawPrincipal(400 ether);

    assertEq(manager.principal(), PRINCIPAL - 400 ether);
    assertEq(token.balanceOf(managerSafe), 400 ether);
    assertEq(token.balanceOf(address(manager)), 0);
  }

  /// @dev the caller cannot name a destination — a compromised MANAGER key can only push funds back
  ///      to the multisig. Proven by moving principalOwner and observing where the funds land.
  function test_withdrawPrincipal_ignoresCallerAsDestination() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(admin);
    manager.setPrincipalOwner(newOwner);

    vm.prank(managerSafe);
    manager.withdrawPrincipal(250 ether);

    assertEq(token.balanceOf(newOwner), 250 ether);
    assertEq(token.balanceOf(managerSafe), 0);
  }

  function test_withdrawPrincipal_revertsAbovePrincipal() public {
    vaultMock.accrue(1_000 ether); // plenty of assets, but principal is the cap
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ExceedsPrincipal.selector);
    manager.withdrawPrincipal(PRINCIPAL + 1);
  }

  function test_withdrawPrincipal_revertsOnZero() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ZeroAmount.selector);
    manager.withdrawPrincipal(0);
  }

  function test_withdrawPrincipal_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.withdrawPrincipal(1 ether);
  }

  /// @dev shares can arrive as a plain ERC20 transfer, which bypasses depositPrincipal entirely.
  ///      Without the correction the transferred position reads as harvestable yield.
  function test_increasePrincipal_correctsDirectShareTransfer() public {
    token.mint(address(this), 700 ether);
    token.approve(address(vaultMock), 700 ether);
    uint256 shares = vaultMock.deposit(700 ether, address(this));
    vaultMock.transfer(address(manager), shares);

    assertEq(manager.claimableYield(), 700 ether); // reads as yield, is principal

    vm.prank(managerSafe);
    manager.increasePrincipal(700 ether);

    assertEq(manager.principal(), PRINCIPAL + 700 ether);
    assertEq(manager.claimableYield(), 0);
  }

  function test_increasePrincipal_revertsOnZero() public {
    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.ZeroAmount.selector);
    manager.increasePrincipal(0);
  }

  function test_increasePrincipal_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.increasePrincipal(1 ether);
  }

  /// @dev a correction that only shrinks claimableYield must stay available during an incident.
  function test_increasePrincipal_worksWhenPaused() public {
    vm.prank(pauser);
    manager.pause();

    vm.prank(managerSafe);
    manager.increasePrincipal(100 ether);
    assertEq(manager.principal(), PRINCIPAL + 100 ether);
  }

  /// @dev pause exists to stop the bot, not to trap the owner's principal.
  function test_withdrawPrincipal_worksWhenPaused() public {
    vm.prank(pauser);
    manager.pause();

    vm.prank(managerSafe);
    manager.withdrawPrincipal(100 ether);
    assertEq(token.balanceOf(managerSafe), 100 ether);
  }
  // ------------------------------------------------------------------ claimYield

  function _pay(address to, uint256 amount) internal pure returns (MoolahVaultAccount.Payment[] memory p) {
    p = new MoolahVaultAccount.Payment[](1);
    p[0] = MoolahVaultAccount.Payment({ to: to, amount: amount });
  }

  function _pay2(
    address to1,
    uint256 a1,
    address to2,
    uint256 a2
  ) internal pure returns (MoolahVaultAccount.Payment[] memory p) {
    p = new MoolahVaultAccount.Payment[](2);
    p[0] = MoolahVaultAccount.Payment({ to: to1, amount: a1 });
    p[1] = MoolahVaultAccount.Payment({ to: to2, amount: a2 });
  }

  function test_claimYield_singleRecipient() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    uint256 total = manager.claimYield(_pay(lsr, 600 ether));

    assertEq(total, 600 ether);
    assertEq(token.balanceOf(lsr), 600 ether);
    assertEq(manager.claimableYield(), 400 ether);
    assertEq(manager.principal(), PRINCIPAL); // untouched
  }

  function test_claimYield_splitsAcrossTwoRecipients() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    uint256 total = manager.claimYield(_pay2(lsr, 440 ether, buyback, 560 ether));

    assertEq(total, 1_000 ether);
    assertEq(token.balanceOf(lsr), 440 ether);
    assertEq(token.balanceOf(buyback), 560 ether);
    assertEq(manager.claimableYield(), 0);
  }

  function test_claimYield_leavesNoResidue() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    manager.claimYield(_pay2(lsr, 1 ether, buyback, 999 ether));

    assertEq(token.balanceOf(address(manager)), 0);
  }

  function test_claimYield_revertsOnEmptyArray() public {
    vaultMock.accrue(1_000 ether);
    MoolahVaultAccount.Payment[] memory empty = new MoolahVaultAccount.Payment[](0);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.ZeroAmount.selector);
    manager.claimYield(empty);
  }

  function test_claimYield_revertsOnAllZeroAmounts() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.ZeroAmount.selector);
    manager.claimYield(_pay2(lsr, 0, buyback, 0));
  }

  function test_claimYield_skipsZeroAmountLeg() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    uint256 total = manager.claimYield(_pay2(lsr, 0, buyback, 700 ether));

    assertEq(total, 700 ether);
    assertEq(token.balanceOf(lsr), 0);
    assertEq(token.balanceOf(buyback), 700 ether);
  }

  function test_claimYield_revertsAboveClaimable() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.ExceedsClaimable.selector);
    manager.claimYield(_pay(lsr, 1_000 ether + 1));
  }

  function test_claimYield_revertsOnUnlistedRecipient() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.NotYieldRecipient.selector);
    manager.claimYield(_pay(stranger, 100 ether));
  }

  /// @dev the whole call must roll back — a valid first leg must not survive an invalid second.
  function test_claimYield_revertsOnUnlistedSecondRecipient_rollsBack() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.NotYieldRecipient.selector);
    manager.claimYield(_pay2(lsr, 500 ether, stranger, 100 ether));

    assertEq(token.balanceOf(lsr), 0);
    assertEq(manager.claimableYield(), 1_000 ether);
  }

  /// @dev a zero-amount leg still has to name a whitelisted address.
  function test_claimYield_revertsOnUnlistedZeroAmountLeg() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.NotYieldRecipient.selector);
    manager.claimYield(_pay2(buyback, 100 ether, stranger, 0));
  }

  function test_claimYield_revertsAfterRecipientRemoved() public {
    vaultMock.accrue(1_000 ether);
    vm.prank(managerSafe);
    manager.removeYieldRecipient(lsr);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.NotYieldRecipient.selector);
    manager.claimYield(_pay(lsr, 100 ether));
  }

  /// @dev C2 stand-in: no clamping. A short vault reverts and the bot retries next cycle.
  function test_claimYield_revertsWhenLiquidityShort() public {
    vaultMock.accrue(1_000 ether);
    vaultMock.setLiquidity(300 ether);

    vm.prank(bot);
    vm.expectRevert(); // ERC4626ExceededMaxWithdraw; the real NotEnoughLiquidity() is fork-tested
    manager.claimYield(_pay(lsr, 800 ether));

    // and the amount previewClaim reports as available does go through
    (, , uint256 claimableNow) = manager.previewClaim();
    assertEq(claimableNow, 300 ether);
    vm.prank(bot);
    manager.claimYield(_pay(lsr, claimableNow));
    assertEq(token.balanceOf(lsr), 300 ether);
  }

  /// @dev the vault is upgradeable. A withdraw that delivers less than it was asked for must revert
  ///      the claim, not top the difference up out of lisUSD donated to this contract.
  function test_claimYield_revertsWhenWithdrawUnderDelivers() public {
    vaultMock.accrue(1_000 ether);
    token.mint(address(manager), 500 ether); // donated balance a claim must never spend
    vaultMock.setWithdrawShortfall(1 ether);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.WithdrawShortfall.selector);
    manager.claimYield(_pay(lsr, 800 ether));

    vaultMock.setWithdrawShortfall(0);
    vm.prank(bot);
    manager.claimYield(_pay(lsr, 800 ether));
    assertEq(token.balanceOf(lsr), 800 ether);
    assertEq(token.balanceOf(address(manager)), 500 ether); // donation untouched
  }

  function test_claimYield_onlyBot() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(managerSafe); // MANAGER is not BOT
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, managerSafe, BOT_ROLE)
    );
    manager.claimYield(_pay(lsr, 100 ether));
  }

  function test_claimYield_revertsWhenPaused() public {
    vaultMock.accrue(1_000 ether);
    vm.prank(pauser);
    manager.pause();

    vm.prank(bot);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    manager.claimYield(_pay(lsr, 100 ether));
  }

  /// @dev principal is not reachable through the yield path: a second claim on unchanged NAV has
  ///      nothing to take. Assert the residual against the vault's own preview arithmetic, not
  ///      against `principal - 1` — the dust bound is one share-wei's worth of assets.
  function test_claimYield_twiceOnUnchangedNav() public {
    vaultMock.accrue(1_000 ether);
    uint256 claimable = manager.claimableYield();

    uint256 expectedRemaining = vaultMock.totalAssets() - claimable;

    vm.prank(bot);
    manager.claimYield(_pay(lsr, claimable));

    assertEq(manager.totalAssets(), expectedRemaining);
    assertLe(expectedRemaining, manager.principal());
    // the shortfall is bounded by one share's asset value, not by 1 wei
    assertGe(expectedRemaining + vaultMock.convertToAssets(1) + 1, manager.principal());
    assertEq(manager.claimableYield(), 0);

    vm.prank(bot);
    vm.expectRevert(MoolahVaultAccount.ExceedsClaimable.selector);
    manager.claimYield(_pay(lsr, 1));
  }

  /// @dev the dust deficit is a floor, not a ratchet: repeated accrue-and-drain rounds must not
  ///      deepen it. Asserted against the share-value bound each round, so the check does not depend
  ///      on which round happens to be worst.
  function test_claimYield_dustFloorDoesNotDeepen() public {
    vaultMock.accrue(1_000 ether);

    for (uint256 round = 0; round < 5; ++round) {
      uint256 claimable = manager.claimableYield();
      if (claimable > 0) {
        vm.prank(bot);
        manager.claimYield(_pay(buyback, claimable));
      }

      uint256 assets = manager.totalAssets();
      uint256 deficit = manager.principal() > assets ? manager.principal() - assets : 0;
      assertLe(deficit, vaultMock.convertToAssets(1) + 1);

      vaultMock.accrue(137 ether);
    }
  }

  /// @dev lisUSD sent here by mistake is not swept by a claim and does not inflate claimableYield.
  function test_claimYield_ignoresDonatedAsset() public {
    vaultMock.accrue(1_000 ether);
    token.mint(address(manager), 42 ether);
    assertEq(manager.claimableYield(), 1_000 ether);

    vm.prank(bot);
    manager.claimYield(_pay(lsr, 1_000 ether));

    assertEq(token.balanceOf(lsr), 1_000 ether);
    assertEq(token.balanceOf(address(manager)), 42 ether); // still there
  }

  function test_claimYield_emitsEvents() public {
    vaultMock.accrue(1_000 ether);

    vm.expectEmit(true, false, false, true, address(manager));
    emit MoolahVaultAccount.YieldPaid(lsr, 300 ether);
    vm.expectEmit(true, false, false, true, address(manager));
    emit MoolahVaultAccount.YieldPaid(buyback, 200 ether);
    vm.expectEmit(false, false, false, true, address(manager));
    emit MoolahVaultAccount.YieldClaimed(500 ether, 1_000 ether);

    vm.prank(bot);
    manager.claimYield(_pay2(lsr, 300 ether, buyback, 200 ether));
  }

  function test_claimYield_duplicateRecipientEntries() public {
    vaultMock.accrue(1_000 ether);

    vm.prank(bot);
    uint256 total = manager.claimYield(_pay2(lsr, 100 ether, lsr, 250 ether));

    assertEq(total, 350 ether);
    assertEq(token.balanceOf(lsr), 350 ether);
  }
  // ------------------------------------------------------------------ emergencyWithdraw

  /// @dev the whole position leaves at once as shares — principal and yield ride out together — and
  ///      the baseline resets to 0. No argument: the call always takes the entire share balance.
  function test_emergencyWithdraw_movesAllSharesToPrincipalOwner() public {
    vaultMock.accrue(1_000 ether);
    uint256 held = vaultMock.balanceOf(address(manager));

    vm.prank(managerSafe);
    uint256 shares = manager.emergencyWithdraw();

    assertEq(shares, held);
    assertEq(vaultMock.balanceOf(managerSafe), held);
    assertEq(vaultMock.balanceOf(address(manager)), 0);
    assertEq(manager.principal(), 0);
    assertEq(manager.totalAssets(), 0);
    assertEq(manager.claimableYield(), 0);
    assertEq(token.balanceOf(managerSafe), 0); // shares moved, not lisUSD
  }

  /// @dev the decisive property: a share transfer never walks the withdraw queue, so the exit works
  ///      with the vault fully illiquid — exactly where withdrawPrincipal and claimYield revert.
  function test_emergencyWithdraw_worksWithZeroLiquidity() public {
    vaultMock.accrue(1_000 ether);
    vaultMock.setLiquidity(0);
    uint256 held = vaultMock.balanceOf(address(manager));

    vm.prank(managerSafe);
    uint256 shares = manager.emergencyWithdraw();

    assertEq(shares, held);
    assertEq(vaultMock.balanceOf(managerSafe), held);
    assertEq(vaultMock.balanceOf(address(manager)), 0);
    assertEq(manager.principal(), 0);
  }

  /// @dev the caller cannot name a destination — the exit follows principalOwner, like withdrawPrincipal.
  function test_emergencyWithdraw_paysPrincipalOwnerNotCaller() public {
    address newOwner = makeAddr("newOwner");
    uint256 held = vaultMock.balanceOf(address(manager));

    vm.prank(admin);
    manager.setPrincipalOwner(newOwner);

    vm.prank(managerSafe);
    uint256 shares = manager.emergencyWithdraw();

    assertEq(shares, held);
    assertEq(vaultMock.balanceOf(newOwner), held);
    assertEq(vaultMock.balanceOf(admin), 0);
    assertEq(vaultMock.balanceOf(managerSafe), 0); // the caller keeps nothing
  }

  /// @dev MANAGER-gated. DEFAULT_ADMIN_ROLE is deliberately NOT accepted directly: it administers
  ///      MANAGER, so its route is to grant itself the role first.
  function test_emergencyWithdraw_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER_ROLE)
    );
    manager.emergencyWithdraw();

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, MANAGER_ROLE)
    );
    manager.emergencyWithdraw();
  }

  /// @dev the pause an incident triggers must not block the exit that same incident calls for.
  function test_emergencyWithdraw_worksWhenPaused() public {
    vm.prank(pauser);
    manager.pause();

    vm.prank(managerSafe);
    manager.emergencyWithdraw();
    assertEq(manager.principal(), 0);
  }

  /// @dev after a loss the position is worth less than the baseline. The exit still moves every share
  ///      and still resets the baseline to 0 — an empty position has no baseline to keep — and that is
  ///      the one write-down in the contract (note 4).
  function test_emergencyWithdraw_afterLossResetsBaseline() public {
    vaultMock.loss(200_000 ether); // NAV now 200k below principal
    assertEq(manager.claimableYield(), 0);
    uint256 held = vaultMock.balanceOf(address(manager));

    vm.prank(managerSafe);
    uint256 shares = manager.emergencyWithdraw();

    assertEq(shares, held);
    assertLt(vaultMock.convertToAssets(shares), PRINCIPAL);
    assertEq(manager.principal(), 0);
    assertEq(vaultMock.balanceOf(address(manager)), 0);
  }

  /// @dev the vault is upgradeable. A share transfer that returns true without moving anything must
  ///      revert, instead of leaving the baseline at 0 with the position still sitting here.
  function test_emergencyWithdraw_revertsWhenSharesDoNotMove() public {
    vaultMock.setTransferNoop(true);

    vm.prank(managerSafe);
    vm.expectRevert(MoolahVaultAccount.SharesRemaining.selector);
    manager.emergencyWithdraw();
  }

  function test_emergencyWithdraw_revertsWithNoShares() public {
    vm.startPrank(managerSafe);
    manager.emergencyWithdraw();
    vm.expectRevert(MoolahVaultAccount.ZeroShares.selector);
    manager.emergencyWithdraw();
    vm.stopPrank();
  }
}

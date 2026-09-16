// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { PositionMigrator } from "../../src/utils/PositionMigrator.sol";
import { YieldAccount } from "../../src/utils/YieldAccount.sol";
import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ISlisBnbProvider } from "../../src/provider/interfaces/IProvider.sol";
import { IStakeManager } from "../../src/provider/interfaces/IStakeManager.sol";

import { Interaction } from "lista-dao-contracts.git/Interaction.sol";
import { SlisBNBProvider } from "lista-dao-contracts.git/ceros/provider/SlisBNBProvider.sol";
import { HelioProviderV2 } from "lista-dao-contracts.git/ceros/upgrades/HelioProviderV2.sol";

interface IProxyAdmin {
  function upgrade(address proxy, address implementation) external;
}

/// @dev The routed-account branch: BNB CDP -> YieldAccount-owned Moolah position, with the CDP side
///      acting on the owner's own address.
contract PositionMigratorYieldAccountTest is Test {
  using MarketParamsLib for MarketParams;

  uint256 constant FORK_BLOCK = 116_433_631;

  IMoolah constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  ISlisBnbProvider constant PROVIDER = ISlisBnbProvider(0x33f7A980a246f9B8FEA2254E3065576E127D4D5f);
  IERC20 constant SLISBNB = IERC20(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B);
  IERC20 constant LISUSD = IERC20(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);
  address constant YIELD_ACCOUNT_OWNER = 0x0966602E47F6a3CA5692529F1D54EcD1d9B09175;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant B0C6 = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant MAINNET_MIGRATOR = 0x2B3E5b695722756130A553E9Bb5A45E16d21D0A4;
  address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address constant BTCB_USER = 0xC5Ca77e168FE2cdbaDe44A9B2ea51B99D8962587;
  address constant PROXY_ADMIN = 0x1Fa3E4718168077975fF4039304CC2e19Ae58c4C;

  MarketParams params;
  Id id;
  IStakeManager stakeManager;
  YieldAccount account;
  PositionMigrator migrator;

  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address pauser = makeAddr("pauser");
  address treasury = makeAddr("treasury");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    params = MarketParams({
      loanToken: address(LISUSD),
      collateralToken: address(SLISBNB),
      oracle: 0xf3afD82A4071f272F403dC176916141f44E6c750,
      irm: 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6,
      lltv: 85 * 1e16
    });
    id = params.id();
    stakeManager = IStakeManager(PROVIDER.STAKE_MANAGER());

    // the YieldAccount that will own the migrated position
    address[] memory receivers = new address[](1);
    receivers[0] = YIELD_ACCOUNT_OWNER;
    YieldAccount accountImpl = new YieldAccount(address(MOOLAH), address(PROVIDER), YIELD_ACCOUNT_OWNER);
    account = YieldAccount(
      address(
        new ERC1967Proxy(
          address(accountImpl),
          abi.encodeCall(
            YieldAccount.initialize,
            (TIMELOCK, manager, pauser, params, treasury, 0.005 ether, YIELD_ACCOUNT_OWNER, receivers)
          )
        )
      )
    );

    address[] memory collaterals = new address[](0);
    PositionMigrator migratorImpl = new PositionMigrator();
    migrator = PositionMigrator(
      address(
        new ERC1967Proxy(
          address(migratorImpl),
          abi.encodeCall(PositionMigrator.initialize, (TIMELOCK, manager, collaterals))
        )
      )
    );

    vm.prank(manager);
    address[] memory wl = new address[](1);
    wl[0] = YIELD_ACCOUNT_OWNER;
    migrator.updateWhitelist(wl, true);

    // routing is storage now: DEFAULT_ADMIN points it at the account and its market
    vm.prank(TIMELOCK);
    migrator.setYieldAccount(address(account), Id.unwrap(id));

    _upgradeCdpContracts();
    vm.mockCall(
      address(migrator.INTERACTION()),
      abi.encodeWithSelector(Interaction.migrator.selector),
      abi.encode(address(migrator))
    );

    // the account authorizes the migrator for the migration window
    vm.prank(TIMELOCK);
    account.setMigrator(address(migrator));
    vm.prank(YIELD_ACCOUNT_OWNER);
    account.setMigratorAuthorization(address(migrator), true);

    // read BOT() before the prank: an external call would consume it
    bytes32 botRole = migrator.BOT();
    vm.prank(TIMELOCK);
    migrator.grantRole(botRole, bot);
  }

  function _upgradeCdpContracts() internal {
    // deploy first: a CREATE consumes vm.prank
    address interactionImpl = address(new Interaction());
    address helioImpl = address(new HelioProviderV2());
    address cdpProviderImpl = address(new SlisBNBProvider());

    vm.startPrank(TIMELOCK);
    IProxyAdmin(PROXY_ADMIN).upgrade(address(migrator.INTERACTION()), interactionImpl);
    IProxyAdmin(PROXY_ADMIN).upgrade(migrator.bnbProvider(), helioImpl);
    IUUPS(migrator.slisBnbProviderCDP()).upgradeTo(cdpProviderImpl);
    vm.stopPrank();
  }

  /// @dev top up the market so the whole debt can be flash-loaned and re-borrowed in one tx
  function _fundMarket(uint256 assets) internal {
    deal(address(LISUSD), address(this), assets);
    LISUSD.approve(address(MOOLAH), assets);
    MOOLAH.supply(params, assets, 0, address(this), "");
  }

  function test_constants() public view {
    assertEq(migrator.YIELD_ACCOUNT_OWNER(), YIELD_ACCOUNT_OWNER);
    assertEq(migrator.yieldAccount(), address(account));
    assertEq(migrator.yieldAccountMarket(), Id.unwrap(id));
  }

  function test_migration_landsUnderAccount() public {
    address cdpBnb = migrator.cdpBnbCollateral();
    migrator.INTERACTION().drip(cdpBnb);
    uint256 cdpDebt = migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER);
    uint256 locked = migrator.INTERACTION().locked(cdpBnb, YIELD_ACCOUNT_OWNER);
    assertGt(cdpDebt, 0, "account owner has no CDP debt at this block");

    // the whole debt is flash-loaned and re-borrowed in one transaction
    _fundMarket(cdpDebt * 2);

    vm.prank(YIELD_ACCOUNT_OWNER);
    migrator.migratePosition(params, true, 0);

    // Moolah position is owned by the account, not the owner address
    Position memory accountPos = MOOLAH.position(id, address(account));
    Position memory ownerPos = MOOLAH.position(id, YIELD_ACCOUNT_OWNER);
    assertGt(accountPos.collateral, 0);
    assertGt(accountPos.borrowShares, 0);
    assertEq(ownerPos.collateral, 0);
    assertEq(ownerPos.borrowShares, 0);

    // the account recorded the BNB principal, so the exchange-rate growth stays with the protocol
    assertApproxEqRel(account.principalBnb(), locked, 0.01e18);
    assertEq(account.trackedCollateral(), accountPos.collateral);
    // both conversion legs round down, so principal converts back to at most the collateral held
    uint256 principalInSlis = stakeManager.convertBnbToSnBnb(account.principalBnb());
    assertLe(principalInSlis, accountPos.collateral);
    assertApproxEqAbs(principalInSlis, accountPos.collateral, 2);

    // the CDP position is emptied on the owner's own address
    assertEq(migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER), 0);
    assertEq(migrator.INTERACTION().locked(cdpBnb, YIELD_ACCOUNT_OWNER), 0);

    // borrowed lisUSD repaid the flash loan, and nothing is stranded in the migrator
    assertEq(LISUSD.balanceOf(address(migrator)), 0);
    assertEq(SLISBNB.balanceOf(address(migrator)), 0);
  }

  function test_ownerCannotMigrateIntoPlainPosition() public {
    _fundMarket(1000 ether);
    // the ordinary entry point routes the owner through the account too
    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("wrong market");
    migrator.migratePosition(_otherMarket(), true, 0);
  }

  function test_migration_revertsWithoutAuthorization() public {
    vm.prank(YIELD_ACCOUNT_OWNER);
    account.setMigratorAuthorization(address(migrator), false);

    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("account not authorized");
    migrator.migratePosition(params, true, 0);
  }

  /// @dev routing off (the default) blocks that owner's migration entirely
  function test_unsetYieldAccount_blocksOwner() public {
    vm.prank(TIMELOCK);
    migrator.setYieldAccount(address(0), bytes32(0));
    assertEq(migrator.yieldAccount(), address(0));

    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("yield account not set");
    migrator.migratePosition(params, true, 0);

    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("yield account not set");
    migrator.migratePosition(params, true, 0);
  }

  /// @dev the setter is DEFAULT_ADMIN's, and it cannot be pointed at an inconsistent pair
  function test_setYieldAccount_accessAndValidation() public {
    bytes32 marketId = Id.unwrap(id);

    vm.prank(manager);
    vm.expectRevert();
    migrator.setYieldAccount(address(account), marketId);

    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert();
    migrator.setYieldAccount(address(account), marketId);

    vm.startPrank(TIMELOCK);
    vm.expectRevert("same yield account");
    migrator.setYieldAccount(address(account), marketId);

    // the market must be the one the account itself operates on
    vm.expectRevert("account market mismatch");
    migrator.setYieldAccount(address(account), keccak256("other market"));

    vm.expectRevert("zero market");
    migrator.setYieldAccount(address(account), bytes32(0));

    vm.expectRevert("market must be zero");
    migrator.setYieldAccount(address(0), marketId);
    vm.stopPrank();
  }

  /* ----------------------------- forced migration ----------------------------- */

  function test_forceMigrate_blockedWhileWindowOpen() public {
    // no deadline set: forced migration is off by default
    assertEq(migrator.migrationDeadline(), 0);
    vm.prank(bot);
    vm.expectRevert("deadline not set");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 30 days);

    vm.prank(bot);
    vm.expectRevert("migration window open");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);
  }

  function test_forceMigrate_afterDeadline_withoutOwnerTx() public {
    address cdpBnb = migrator.cdpBnbCollateral();
    migrator.INTERACTION().drip(cdpBnb);
    uint256 cdpDebt = migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER);
    uint256 locked = migrator.INTERACTION().locked(cdpBnb, YIELD_ACCOUNT_OWNER);
    _fundMarket(cdpDebt * 2);

    // warp only just past the deadline: a long warp makes the oracle price stale
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    // the owner sends no transaction here — the bot does the whole thing
    vm.prank(bot);
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);

    Position memory accountPos = MOOLAH.position(id, address(account));
    assertGt(accountPos.collateral, 0);
    assertGt(accountPos.borrowShares, 0);
    assertEq(MOOLAH.position(id, YIELD_ACCOUNT_OWNER).collateral, 0);
    assertApproxEqRel(account.principalBnb(), locked, 0.01e18);
    // the CDP position is emptied
    assertEq(migrator.INTERACTION().locked(cdpBnb, YIELD_ACCOUNT_OWNER), 0);
    assertEq(migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER), 0);

    // the owner keeps its normal rights on the migrated position
    vm.prank(YIELD_ACCOUNT_OWNER);
    account.withdraw(1 ether, YIELD_ACCOUNT_OWNER);
    assertGt(SLISBNB.balanceOf(YIELD_ACCOUNT_OWNER), 0);
  }

  function test_forceMigrate_botOnly() public {
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert();
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);

    vm.prank(manager);
    vm.expectRevert();
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);
  }

  function test_forceMigrate_stillNeedsAccountAuthorization() public {
    vm.prank(YIELD_ACCOUNT_OWNER);
    account.setMigratorAuthorization(address(migrator), false);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(bot);
    vm.expectRevert("account not authorized");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);

    // MANAGER can restore it without the owner, since the address is TimeLock-chosen
    vm.prank(manager);
    account.setMigratorAuthorization(address(migrator), true);
    migrator.INTERACTION().drip(migrator.cdpBnbCollateral());
    _fundMarket(migrator.INTERACTION().borrowed(migrator.cdpBnbCollateral(), YIELD_ACCOUNT_OWNER) * 2);
    vm.prank(bot);
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);
    assertGt(MOOLAH.position(id, address(account)).collateral, 0);
  }

  function test_migrationDeadline_managerCanOnlyExtend() public {
    vm.prank(manager);
    vm.expectRevert("deadline not set");
    migrator.extendMigrationDeadline(block.timestamp + 1 days);

    uint256 deadline = block.timestamp + 30 days;
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(deadline);

    // MANAGER cannot pull it forward
    vm.prank(manager);
    vm.expectRevert("not an extension");
    migrator.extendMigrationDeadline(deadline - 1 days);

    vm.prank(manager);
    migrator.extendMigrationDeadline(deadline + 10 days);
    assertEq(migrator.migrationDeadline(), deadline + 10 days);

    // and MANAGER cannot set it at all
    vm.prank(manager);
    vm.expectRevert();
    migrator.setMigrationDeadline(block.timestamp);
  }

  /* ----------------------------- routing target ----------------------------- */

  /// @dev the routed account must be owned by YIELD_ACCOUNT_OWNER. Without this, admin could point
  ///      the routing at an account a stranger owns -- same market, so every other check passes --
  ///      and the whole migrated position would land somewhere the owner cannot touch.
  function test_setYieldAccount_rejectsForeignOwner() public {
    address stranger = makeAddr("stranger");
    address[] memory receivers = new address[](1);
    receivers[0] = stranger;
    YieldAccount foreignImpl = new YieldAccount(address(MOOLAH), address(PROVIDER), stranger);
    YieldAccount foreign = YieldAccount(
      address(
        new ERC1967Proxy(
          address(foreignImpl),
          abi.encodeCall(
            YieldAccount.initialize,
            (TIMELOCK, manager, pauser, params, treasury, 0.005 ether, stranger, receivers)
          )
        )
      )
    );
    // only the owner differs; the market matches, so the pre-existing checks would all pass
    assertEq(foreign.OWNER(), stranger);
    assertEq(Id.unwrap(foreign.marketId()), Id.unwrap(id));

    vm.prank(TIMELOCK);
    vm.expectRevert("account owner mismatch");
    migrator.setYieldAccount(address(foreign), Id.unwrap(id));

    assertEq(migrator.yieldAccount(), address(account), "routing changed");
  }

  /// @dev the two admin setters read nothing from each other, so neither ordering deadlocks and a
  ///      single TimeLock batch can carry both
  function test_routingSetters_haveNoCircularDependency() public {
    address[] memory receivers = new address[](1);
    receivers[0] = YIELD_ACCOUNT_OWNER;
    YieldAccount freshImpl = new YieldAccount(address(MOOLAH), address(PROVIDER), YIELD_ACCOUNT_OWNER);
    YieldAccount fresh = YieldAccount(
      address(
        new ERC1967Proxy(
          address(freshImpl),
          abi.encodeCall(
            YieldAccount.initialize,
            (TIMELOCK, manager, pauser, params, treasury, 0.005 ether, YIELD_ACCOUNT_OWNER, receivers)
          )
        )
      )
    );
    assertEq(fresh.migrator(), address(0), "fresh account has no migrator yet");

    // routing can be pointed at an account that has never heard of this migrator
    vm.prank(TIMELOCK);
    migrator.setYieldAccount(address(fresh), Id.unwrap(id));

    // the only gate left is the authorization, i.e. the chain is linear, not circular
    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("account not authorized");
    migrator.migratePosition(params, true, 0);

    vm.prank(TIMELOCK);
    fresh.setMigrator(address(migrator));
    vm.prank(YIELD_ACCOUNT_OWNER);
    fresh.setMigratorAuthorization(address(migrator), true);
    assertTrue(MOOLAH.isAuthorized(address(fresh), address(migrator)));
  }

  /// @dev the slisBNB-ilk branch is dead code for the routed account. The check sits ahead of the
  ///      CDP reads so "no debt to migrate" does not mask it.
  function test_routedMigration_requiresBnb() public {
    vm.prank(YIELD_ACCOUNT_OWNER);
    vm.expectRevert("routed migration must be bnb");
    migrator.migratePosition(params, false, 0);
  }

  /* ----------------------------- deadline bounds ----------------------------- */

  /// @dev a deadline in the past arms `forceMigrate` in the same block, skipping the window the
  ///      setter exists to grant
  function test_setMigrationDeadline_rejectsPast() public {
    vm.startPrank(TIMELOCK);
    vm.expectRevert("deadline in the past");
    migrator.setMigrationDeadline(block.timestamp - 365 days);

    vm.expectRevert("deadline in the past");
    migrator.setMigrationDeadline(block.timestamp);
    vm.stopPrank();

    assertEq(migrator.migrationDeadline(), 0);
  }

  /// @dev zero must stay reachable: it is the switch that turns `forceMigrate` back off
  function test_setMigrationDeadline_zeroStillDisablesForce() public {
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 30 days);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(0);
    assertEq(migrator.migrationDeadline(), 0);

    vm.prank(bot);
    vm.expectRevert("deadline not set");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);
  }

  /// @dev an extension has to reopen the window; nudging an already-passed deadline forward only
  ///      looks like a reprieve while `forceMigrate` stays live
  function test_extendMigrationDeadline_rejectsPast() public {
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    uint256 old = migrator.migrationDeadline();
    vm.warp(block.timestamp + 10 days);

    vm.prank(manager);
    vm.expectRevert("deadline in the past");
    migrator.extendMigrationDeadline(old + 1 days);

    // a real reprieve still works, and closes the forced window again
    vm.prank(manager);
    migrator.extendMigrationDeadline(block.timestamp + 5 days);
    vm.prank(bot);
    vm.expectRevert("migration window open");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);
  }

  /* ----------------------------- forced migration, other accounts ----------------------------- */

  /// @dev the widened signature has to thread `onBehalf` through to the CDP read. A whitelisted
  ///      account with no CDP debt stops at its own empty position; with the old hardcoded
  ///      YIELD_ACCOUNT_OWNER this would have read the whale's position and proceeded.
  function test_forceMigrate_readsTheGivenAccountsCdp() public {
    address other = makeAddr("otherCdpUser");
    address[] memory wl = new address[](1);
    wl[0] = other;
    vm.prank(manager);
    migrator.updateWhitelist(wl, true);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    // the whale does have debt, so reverting here can only mean `other` was the account read
    address cdpBnb = migrator.cdpBnbCollateral();
    assertGt(migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER), 0, "whale has no debt");
    assertEq(migrator.INTERACTION().borrowed(cdpBnb, other), 0, "other should be empty");

    vm.prank(bot);
    vm.expectRevert("no debt to migrate");
    migrator.forceMigrate(other, params, true, 0);
  }

  /// @dev Exercises the real deployed migrator proxy, upgraded to this build, instead of the test's
  ///      own instance. The non-BNB path needs that: `Interaction.withdrawFor` reads `migrator()`
  ///      with an internal call, so setUp's `vm.mockCall` cannot redirect it and only the real
  ///      migrator address is accepted. This also mirrors what the mainnet upgrade actually does.
  function _realMigrator() internal returns (PositionMigrator real) {
    address interactionProxy = address(migrator.INTERACTION());
    address newImpl = address(new PositionMigrator());

    vm.startPrank(TIMELOCK);
    // setUp downgraded Interaction to the lib source, whose `migrator()` is still a `pure` stub
    // returning 0; put the deployed implementation back
    IProxyAdmin(PROXY_ADMIN).upgrade(interactionProxy, 0xCe338985A4B241605955Dd77C917aA040E110ED3);
    PositionMigrator(MAINNET_MIGRATOR).upgradeToAndCall(newImpl, "");
    vm.stopPrank();

    real = PositionMigrator(MAINNET_MIGRATOR);
    bytes32 botRole = real.BOT();
    vm.prank(TIMELOCK);
    real.grantRole(botRole, bot);
  }

  function _btcbMarket() internal pure returns (MarketParams memory) {
    return
      MarketParams({
        loanToken: 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5,
        collateralToken: BTCB,
        oracle: 0xf3afD82A4071f272F403dC176916141f44E6c750,
        irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
        lltv: 86 * 1e16
      });
  }

  /// @dev the widened signature's real purpose: a non-routed account with a BTCB CDP position is
  ///      force-migrated into its own Moolah position, keeping the collateral. The lisUSD/BTCB 86%
  ///      market has no broker and no provider — the branch BTCB must take.
  /// @dev the account must have authorized the migrator on Moolah first: without a YieldAccount
  ///      there is nothing the protocol can authorize on its behalf, so this is only half-forced.
  function test_forceMigrate_btcbLandsInOwnPosition() public {
    PositionMigrator real = _realMigrator();
    MarketParams memory btcbParams = _btcbMarket();
    Id btcbId = btcbParams.id();
    assertEq(MOOLAH.brokers(btcbId), address(0), "market must have no broker");
    assertTrue(real.isWhitelisted(BTCB_USER), "user already whitelisted on mainnet");

    real.INTERACTION().drip(BTCB);
    uint256 debt = real.INTERACTION().borrowed(BTCB, BTCB_USER);
    uint256 locked = real.INTERACTION().locked(BTCB, BTCB_USER);
    assertGt(debt, 0, "picked account has no BTCB debt at this block");

    // the account's own opt-in; the protocol cannot supply this for a plain position
    vm.prank(BTCB_USER);
    MOOLAH.setAuthorization(address(real), true);

    vm.prank(TIMELOCK);
    real.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(bot);
    real.forceMigrate(BTCB_USER, btcbParams, false, 0);

    // landed on the account itself, not any YieldAccount
    Position memory own = MOOLAH.position(btcbId, BTCB_USER);
    assertApproxEqAbs(own.collateral, locked, 1, "collateral did not land on the account");
    assertGt(own.borrowShares, 0, "no debt was carried over");

    // CDP emptied, nothing stranded in the migrator
    assertEq(real.INTERACTION().borrowed(BTCB, BTCB_USER), 0, "CDP debt remains");
    assertEq(real.INTERACTION().locked(BTCB, BTCB_USER), 0, "CDP collateral remains");
    assertEq(LISUSD.balanceOf(address(real)), 0);
    assertEq(IERC20(BTCB).balanceOf(address(real)), 0);
  }

  /// @dev without the account's own Moolah authorization the borrow leg cannot run
  function test_forceMigrate_otherAccountNeedsMoolahAuthorization() public {
    PositionMigrator real = _realMigrator();
    MarketParams memory btcbParams = _btcbMarket();

    vm.prank(TIMELOCK);
    real.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    assertFalse(MOOLAH.isAuthorized(BTCB_USER, address(real)), "precondition: not authorized");
    vm.prank(bot);
    vm.expectRevert(bytes("unauthorized"));
    real.forceMigrate(BTCB_USER, btcbParams, false, 0);
  }

  function test_forceMigrate_rejectsNonWhitelisted() public {
    address stranger = makeAddr("strangerCdpUser");
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(bot);
    vm.expectRevert("not whitelisted");
    migrator.forceMigrate(stranger, params, true, 0);
  }

  /// @dev widening the signature must not open a slisBNB-ilk route for the routed account
  function test_forceMigrate_routedAccountStillRequiresBnb() public {
    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(bot);
    vm.expectRevert("routed migration must be bnb");
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, false, 0);
  }

  /// @dev the event has to name the account now that more than one can be forced
  function test_forceMigrate_eventNamesTheAccount() public {
    address cdpBnb = migrator.cdpBnbCollateral();
    migrator.INTERACTION().drip(cdpBnb);
    uint256 debt = migrator.INTERACTION().borrowed(cdpBnb, YIELD_ACCOUNT_OWNER);
    _fundMarket(debt * 2);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.recordLogs();
    vm.prank(bot);
    migrator.forceMigrate(YIELD_ACCOUNT_OWNER, params, true, 0);

    VmSafe.Log[] memory logs = vm.getRecordedLogs();
    bool seen;
    for (uint256 i = 0; i < logs.length; ++i) {
      if (logs[i].topics[0] == PositionMigrator.ForcedMigration.selector) {
        seen = true;
        assertEq(address(uint160(uint256(logs[i].topics[1]))), bot, "bot");
        assertEq(address(uint160(uint256(logs[i].topics[2]))), YIELD_ACCOUNT_OWNER, "onBehalf");
      }
    }
    assertTrue(seen, "ForcedMigration not emitted");
  }

  function _otherMarket() internal view returns (MarketParams memory) {
    MarketParams memory other = params;
    other.lltv = 86 * 1e16;
    return other;
  }
}

interface IUUPS {
  function upgradeTo(address newImplementation) external;
}

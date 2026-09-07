// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
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
    migrator.forceMigrate(params, 0);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 30 days);

    vm.prank(bot);
    vm.expectRevert("migration window open");
    migrator.forceMigrate(params, 0);
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
    migrator.forceMigrate(params, 0);

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
    migrator.forceMigrate(params, 0);

    vm.prank(manager);
    vm.expectRevert();
    migrator.forceMigrate(params, 0);
  }

  function test_forceMigrate_stillNeedsAccountAuthorization() public {
    vm.prank(YIELD_ACCOUNT_OWNER);
    account.setMigratorAuthorization(address(migrator), false);

    vm.prank(TIMELOCK);
    migrator.setMigrationDeadline(block.timestamp + 1);
    vm.warp(block.timestamp + 2);

    vm.prank(bot);
    vm.expectRevert("account not authorized");
    migrator.forceMigrate(params, 0);

    // MANAGER can restore it without the owner, since the address is TimeLock-chosen
    vm.prank(manager);
    account.setMigratorAuthorization(address(migrator), true);
    migrator.INTERACTION().drip(migrator.cdpBnbCollateral());
    _fundMarket(migrator.INTERACTION().borrowed(migrator.cdpBnbCollateral(), YIELD_ACCOUNT_OWNER) * 2);
    vm.prank(bot);
    migrator.forceMigrate(params, 0);
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

  function _otherMarket() internal view returns (MarketParams memory) {
    MarketParams memory other = params;
    other.lltv = 86 * 1e16;
    return other;
  }
}

interface IUUPS {
  function upgradeTo(address newImplementation) external;
}

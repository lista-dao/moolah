// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { PositionMigrator } from "../../src/utils/PositionMigrator.sol";
import { IBnbProviderCdp } from "../../src/utils/interfaces/ICdpProvider.sol";
import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

/// @dev `batchForceMigrate` on the deployed migrator proxy, upgraded to this build. At this block the
///      deployed CDP contracts already honour `Interaction.migrator()`, so nothing is mocked. The
///      migrator registers itself as the lisUSD provider for the call only, which needs Moolah MANAGER.
contract PositionMigratorBatchTest is Test {
  using MarketParamsLib for MarketParams;

  uint256 constant FORK_BLOCK = 126_448_439;

  IMoolah constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  PositionMigrator constant MIGRATOR = PositionMigrator(0x2B3E5b695722756130A553E9Bb5A45E16d21D0A4);
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant B0C6 = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address constant BNB_STRATEGY = 0x6F28FeC449dbd2056b76ac666350Af8773E03873;
  /// @dev the 85% lisUSD/slisBNB market: same pair as MARKET_SLISBNB, but not a forced-migration target
  bytes32 constant OTHER_SLISBNB_MARKET = 0x7fe248d8459a88e50e8582c71219edbce1079437e58190aeab41ac503694f0a5;
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

  // whitelisted CDP accounts with debt at FORK_BLOCK, one per collateral kind
  address constant BNB_USER = 0xD4cf2A5FcC9c65f9f5d8AF9Cb515F9edD48b3362; // ceaBNBc -> slisBNB market
  address constant SLISBNB_USER = 0xc6160F5bC3C673AC390f11c492E8ED0d0693579A;
  address constant BTCB_USER = 0xC5Ca77e168FE2cdbaDe44A9B2ea51B99D8962587;
  address constant WBETH_USER = 0x68Ae6831258C216856C89a910DCe7E4e4d7A4819;

  address bot = makeAddr("bot");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    // deploy first: a CREATE consumes vm.prank
    address newImpl = address(new PositionMigrator());
    bytes32 botRole = MIGRATOR.BOT();

    // the TimeLock batch: upgrade, BOT, deadline, Moolah MANAGER for the migrator
    vm.startPrank(TIMELOCK);
    MIGRATOR.upgradeToAndCall(newImpl, "");
    MIGRATOR.grantRole(botRole, bot);
    MIGRATOR.setMigrationDeadline(block.timestamp + 1);
    IAccessControl(address(MOOLAH)).grantRole(MANAGER_ROLE, address(MIGRATOR));
    vm.stopPrank();

    vm.warp(block.timestamp + 2);
  }

  function _params(bytes32 marketId) internal view returns (MarketParams memory) {
    return MOOLAH.idToMarketParams(Id.wrap(marketId));
  }

  function _entry(
    address user,
    bytes32 marketId,
    bool isBnb
  ) internal view returns (PositionMigrator.ForceMigration memory) {
    uint256 minSlisBnb;
    if (isBnb) {
      uint256 locked = MIGRATOR.INTERACTION().locked(MIGRATOR.cdpBnbCollateral(), user);
      minSlisBnb = IBnbProviderCdp(MIGRATOR.bnbProvider()).estimateInToken(BNB_STRATEGY, locked);
    }
    return PositionMigrator.ForceMigration(user, _params(marketId), isBnb, minSlisBnb);
  }

  function _one(
    PositionMigrator.ForceMigration memory e
  ) internal pure returns (PositionMigrator.ForceMigration[] memory a) {
    a = new PositionMigrator.ForceMigration[](1);
    a[0] = e;
  }

  function _assertNoLisUsdProvider() internal view {
    assertEq(MOOLAH.providers(Id.wrap(MIGRATOR.MARKET_SLISBNB()), LISUSD), address(0), "slisBNB market provider left");
    assertEq(MOOLAH.providers(Id.wrap(MIGRATOR.MARKET_BTCB()), LISUSD), address(0), "BTCB market provider left");
    assertEq(MOOLAH.providers(Id.wrap(MIGRATOR.MARKET_WBETH()), LISUSD), address(0), "wBETH market provider left");
  }

  function test_TOKEN_isLisUsd() public view {
    assertEq(MIGRATOR.TOKEN(), LISUSD);
  }

  /// @dev the hardcoded ids must be live lisUSD markets of the CDP collaterals, with no broker
  function test_targetMarkets() public view {
    bytes32[3] memory ids = [MIGRATOR.MARKET_SLISBNB(), MIGRATOR.MARKET_BTCB(), MIGRATOR.MARKET_WBETH()];
    address[3] memory colls = [SLISBNB, BTCB, WBETH];
    for (uint256 i = 0; i < 3; i++) {
      MarketParams memory p = _params(ids[i]);
      assertEq(p.loanToken, LISUSD, "loan token");
      assertEq(p.collateralToken, colls[i], "collateral");
      assertEq(Id.unwrap(p.id()), ids[i], "id");
      assertEq(MOOLAH.brokers(Id.wrap(ids[i])), address(0), "broker");
    }
  }

  /// @dev one call per collateral kind, none of the accounts authorized the migrator on Moolah:
  ///      every CDP position lands in its owner's Moolah position and the provider is gone afterwards
  function test_batchForceMigrate_migratesEveryCollateralKind() public {
    PositionMigrator.ForceMigration[] memory entries = new PositionMigrator.ForceMigration[](4);
    entries[0] = _entry(BNB_USER, MIGRATOR.MARKET_SLISBNB(), true);
    entries[1] = _entry(SLISBNB_USER, MIGRATOR.MARKET_SLISBNB(), false);
    entries[2] = _entry(BTCB_USER, MIGRATOR.MARKET_BTCB(), false);
    entries[3] = _entry(WBETH_USER, MIGRATOR.MARKET_WBETH(), false);
    address[4] memory cdpColls = [MIGRATOR.cdpBnbCollateral(), SLISBNB, BTCB, WBETH];

    uint256 expected;
    for (uint256 i = 0; i < 4; i++) {
      MIGRATOR.INTERACTION().drip(cdpColls[i]);
      uint256 debt = MIGRATOR.INTERACTION().borrowed(cdpColls[i], entries[i].onBehalf);
      assertGt(debt, 0, "picked account has no debt at this block");
      assertFalse(MOOLAH.isAuthorized(entries[i].onBehalf, address(MIGRATOR)), "account authorized the migrator");
      expected += debt;
    }

    vm.prank(bot);
    uint256 total = MIGRATOR.batchForceMigrate(entries);
    assertEq(total, expected, "migrated debt");

    for (uint256 i = 0; i < 4; i++) {
      address user = entries[i].onBehalf;
      assertEq(MIGRATOR.INTERACTION().borrowed(cdpColls[i], user), 0, "CDP debt remains");
      assertEq(MIGRATOR.INTERACTION().locked(cdpColls[i], user), 0, "CDP collateral remains");
      Position memory pos = MOOLAH.position(entries[i].marketParams.id(), user);
      assertGt(pos.borrowShares, 0, "no Moolah debt");
      assertGt(pos.collateral, 0, "no Moolah collateral");
    }

    _assertNoLisUsdProvider();
    assertEq(
      MOOLAH.providers(Id.wrap(MIGRATOR.MARKET_SLISBNB()), SLISBNB),
      MIGRATOR.slisBnbProviderLending(),
      "collateral provider changed"
    );
    assertEq(IERC20(LISUSD).balanceOf(address(MIGRATOR)), 0);
    assertEq(IERC20(SLISBNB).balanceOf(address(MIGRATOR)), 0);
    assertEq(IERC20(BTCB).balanceOf(address(MIGRATOR)), 0);
    assertEq(IERC20(WBETH).balanceOf(address(MIGRATOR)), 0);
  }

  function test_batchForceMigrate_botOnly() public {
    PositionMigrator.ForceMigration[] memory entries = _one(_entry(BTCB_USER, MIGRATOR.MARKET_BTCB(), false));
    bytes32 botRole = MIGRATOR.BOT();
    address[3] memory callers = [makeAddr("stranger"), B0C6, TIMELOCK];
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(callers[i]);
      vm.expectRevert(
        abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], botRole)
      );
      MIGRATOR.batchForceMigrate(entries);
    }
  }

  /// @dev a lisUSD market outside the three targets is refused before the migrator registers there
  function test_batchForceMigrate_rejectsMarketOutsideTargets() public {
    PositionMigrator.ForceMigration[] memory entries = _one(_entry(SLISBNB_USER, OTHER_SLISBNB_MARKET, false));
    assertEq(entries[0].marketParams.loanToken, LISUSD, "precondition: a lisUSD market");

    vm.prank(bot);
    vm.expectRevert("market not allowed");
    MIGRATOR.batchForceMigrate(entries);
    assertEq(MOOLAH.providers(Id.wrap(OTHER_SLISBNB_MARKET), LISUSD), address(0));
  }

  function test_batchForceMigrate_needsMoolahManager() public {
    vm.prank(TIMELOCK);
    IAccessControl(address(MOOLAH)).revokeRole(MANAGER_ROLE, address(MIGRATOR));

    PositionMigrator.ForceMigration[] memory entries = _one(_entry(BTCB_USER, MIGRATOR.MARKET_BTCB(), false));
    vm.prank(bot);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(MIGRATOR), MANAGER_ROLE)
    );
    MIGRATOR.batchForceMigrate(entries);
  }

  /// @dev an existing lisUSD registration is neither overwritten nor later deleted by the batch
  function test_batchForceMigrate_slotTakenReverts() public {
    Id btcbId = Id.wrap(MIGRATOR.MARKET_BTCB());
    vm.prank(B0C6);
    MOOLAH.setProvider(btcbId, address(MIGRATOR), true);

    PositionMigrator.ForceMigration[] memory entries = _one(_entry(BTCB_USER, MIGRATOR.MARKET_BTCB(), false));
    vm.prank(bot);
    vm.expectRevert("already set");
    MIGRATOR.batchForceMigrate(entries);
    assertEq(MOOLAH.providers(btcbId, LISUSD), address(MIGRATOR), "existing registration changed");
  }

  /// @dev one failing entry rolls back the whole call: earlier entries and the registration included
  function test_batchForceMigrate_failingEntryRevertsAll() public {
    PositionMigrator.ForceMigration[] memory entries = new PositionMigrator.ForceMigration[](2);
    entries[0] = _entry(WBETH_USER, MIGRATOR.MARKET_WBETH(), false);
    entries[1] = _entry(makeAddr("strangerCdpUser"), MIGRATOR.MARKET_WBETH(), false);
    uint256 debtBefore = MIGRATOR.INTERACTION().borrowed(WBETH, WBETH_USER);

    vm.prank(bot);
    vm.expectRevert("not whitelisted");
    MIGRATOR.batchForceMigrate(entries);

    assertEq(MIGRATOR.INTERACTION().borrowed(WBETH, WBETH_USER), debtBefore, "first entry was not rolled back");
    _assertNoLisUsdProvider();
  }

  function test_batchForceMigrate_rejectsEmpty() public {
    vm.prank(bot);
    vm.expectRevert("no entries");
    MIGRATOR.batchForceMigrate(new PositionMigrator.ForceMigration[](0));
  }

  /// @dev the batch path keeps the single path's deadline gate
  function test_batchForceMigrate_respectsDeadline() public {
    PositionMigrator.ForceMigration[] memory entries = _one(_entry(BTCB_USER, MIGRATOR.MARKET_BTCB(), false));

    vm.prank(TIMELOCK);
    MIGRATOR.setMigrationDeadline(0);
    vm.prank(bot);
    vm.expectRevert("deadline not set");
    MIGRATOR.batchForceMigrate(entries);

    vm.prank(TIMELOCK);
    MIGRATOR.setMigrationDeadline(block.timestamp + 1 days);
    vm.prank(bot);
    vm.expectRevert("migration window open");
    MIGRATOR.batchForceMigrate(entries);
  }

  /// @dev outside a batch nothing registers the migrator, so the single path still needs the
  ///      account's own Moolah authorization, as before this change
  function test_forceMigrate_unchangedOutsideBatch() public {
    MarketParams memory p = _params(MIGRATOR.MARKET_BTCB());
    vm.prank(bot);
    vm.expectRevert("unauthorized");
    MIGRATOR.forceMigrate(BTCB_USER, p, false, 0);
  }
}

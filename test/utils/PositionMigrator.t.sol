pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import { PositionMigrator } from "../../src/utils/PositionMigrator.sol";
import { IMoolah, MarketParams, Id, Position, Market } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import { Interaction } from "lista-dao-contracts.git/Interaction.sol";
import { SlisBNBProvider } from "lista-dao-contracts.git/ceros/provider/SlisBNBProvider.sol";
import { HelioProviderV2 } from "lista-dao-contracts.git/ceros/upgrades/HelioProviderV2.sol";

interface IProxyAdmin {
  function upgrade(address proxy, address implementation) external;
}

interface IUUPSUpgradeable {
  function upgradeTo(address newImplementation) external;
}

contract PositionMigratorTest is Test {
  PositionMigrator migrator;
  using MarketParamsLib for MarketParams;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address slisBnb = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address btcb = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;

  address user_btcb = 0x52C96137b083385510f19bA7b79b1929E3c99bcA;
  address user_slisBnb = 0xf9521D4954E3972cA2773B1A34E406F6ab8C6e67;
  address user_bnb = 0x713bd67b2cd60b6717c39213Caa874d2224f00e7;

  Id slisBnb_marketId = Id.wrap(bytes32(0x7fe248d8459a88e50e8582c71219edbce1079437e58190aeab41ac503694f0a5));
  MarketParams slisBnb_marketParams =
    MarketParams({
      loanToken: lisUSD,
      collateralToken: slisBnb,
      oracle: 0xf3afD82A4071f272F403dC176916141f44E6c750,
      irm: 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6,
      lltv: 85 * 1e16
    });

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 85721000);

    address[] memory collaterals = new address[](2);
    collaterals[0] = slisBnb;
    collaterals[1] = btcb;

    PositionMigrator impl = new PositionMigrator();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(PositionMigrator.initialize.selector, admin, manager, collaterals)
    );
    migrator = PositionMigrator(address(proxy));

    vm.startPrank(manager);
    address[] memory whitelist = new address[](2);
    whitelist[0] = user_bnb;
    whitelist[1] = user_slisBnb;
    bool[] memory status = new bool[](2);
    status[0] = true;
    status[1] = true;
    migrator.updateWhitelist(whitelist, status);
    vm.stopPrank();

    upgrade_Interaction();
    upgrade_HelioProviderV2();
    upgrade_SlisBNBProvider();

    // mock function to return migrator address
    vm.mockCall(
      0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4,
      abi.encodeWithSelector(Interaction.migrator.selector),
      abi.encode(address(migrator))
    );
  }

  function upgrade_Interaction() public {
    Interaction interactionImpl = new Interaction();
    address proxyAdmin = 0x1Fa3E4718168077975fF4039304CC2e19Ae58c4C;
    vm.startPrank(admin);
    IProxyAdmin(proxyAdmin).upgrade(address(migrator.INTERACTION()), address(interactionImpl));
  }

  function upgrade_HelioProviderV2() public {
    HelioProviderV2 helioProviderV2Impl = new HelioProviderV2();
    address proxyAdmin = 0x1Fa3E4718168077975fF4039304CC2e19Ae58c4C;
    vm.startPrank(admin);
    IProxyAdmin(proxyAdmin).upgrade(migrator.bnbProvider(), address(helioProviderV2Impl));
  }

  function upgrade_SlisBNBProvider() public {
    SlisBNBProvider slisBNBProviderImpl = new SlisBNBProvider();

    vm.startPrank(admin);
    IUUPSUpgradeable(migrator.slisBnbProviderCDP()).upgradeTo(address(slisBNBProviderImpl));
  }

  function getCdpCollateralAmount(address user, address coll) public view returns (uint256) {
    return migrator.INTERACTION().free(coll, user) + migrator.INTERACTION().locked(coll, user);
  }

  function getCdpDebt(address user, address coll) public view returns (uint256) {
    return migrator.INTERACTION().borrowed(coll, user);
  }

  function getPosititon(address user, Id marketId) public view returns (uint256, uint256) {
    Position memory position = migrator.MOOLAH().position(marketId, user);
    return (position.collateral, position.borrowShares);
  }

  function getMarketAsset(Id marketId) public view returns (uint256) {
    Market memory market = migrator.MOOLAH().market(marketId);
    return market.totalBorrowAssets;
  }

  function test_initialize() public {
    assertEq(address(migrator.MOOLAH()), 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
    assertEq(address(migrator.INTERACTION()), 0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4);
    assertEq(migrator.LISUSD(), 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);
    assertEq(migrator.bnbProvider(), 0xa835F890Fcde7679e7F7711aBfd515d2A267Ed0B);
    assertEq(migrator.slisBnbProviderCDP(), 0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b);
    assertEq(migrator.slisBnbProviderLending(), 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f);

    assertTrue(migrator.isCollateralSupported(slisBnb));
    assertTrue(migrator.isCollateralSupported(btcb));

    assertTrue(migrator.isWhitelisted(user_bnb));
    assertTrue(migrator.isWhitelisted(user_slisBnb));

    assertTrue(migrator.hasRole(migrator.MANAGER(), manager));
    assertTrue(migrator.hasRole(migrator.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_migratePosition_slisBnb() public {
    vm.startPrank(user_slisBnb);

    (uint256 beforeCollateral, uint256 beforeBorrowShares) = getPosititon(user_slisBnb, slisBnb_marketId);
    uint256 beforeLisUSD = IERC20(lisUSD).balanceOf(user_slisBnb);
    uint256 beforeCdpCollateral = getCdpCollateralAmount(user_slisBnb, slisBnb);
    uint beforeMarketAsset = getMarketAsset(slisBnb_marketId);

    vm.expectRevert("unauthorized");
    migrator.migratePosition(slisBnb_marketParams, false);

    migrator.MOOLAH().setAuthorization(address(migrator), true);
    uint cdpDebt = migrator.migratePosition(slisBnb_marketParams, false);

    // CDP postion should be cleared
    assertEq(getCdpDebt(user_slisBnb, slisBnb), 0, "CDP debt should be cleared after migration");
    assertEq(getCdpCollateralAmount(user_slisBnb, slisBnb), 0, "CDP collateral should be cleared after migration");

    // migrated position should have correct collateral amount
    (uint256 afterCollateral, uint afterBorrowShares) = getPosititon(user_slisBnb, slisBnb_marketId);
    assertEq(
      afterCollateral,
      beforeCollateral + beforeCdpCollateral,
      "Moolah position should have correct collateral amount"
    );

    // user's lisUSD balance should be the same after migration since the migrated position is fully collateralized
    uint256 afterLisUSD = IERC20(lisUSD).balanceOf(user_slisBnb);
    assertEq(afterLisUSD, beforeLisUSD, "User's lisUSD balance should not change after migration");

    // check market total borrow asset to ensure the borrow shares are correctly calculated
    uint256 afterMarketAsset = getMarketAsset(slisBnb_marketId);
    // assertEq(afterMarketAsset, beforeMarketAsset + cdpDebt, "Market total borrow asset should increase by the migrated debt amount");
  }

  // CDP BNB collateral will migrate to slisBNB/lisUSD market
  function test_migratePosition_Bnb() public {
    vm.startPrank(user_bnb);

    (uint256 beforeCollateral, uint256 beforeBorrowShares) = getPosititon(user_bnb, slisBnb_marketId);
    uint256 beforeLisUSD = IERC20(lisUSD).balanceOf(user_bnb);
    uint256 beforeCdpCollateral = getCdpCollateralAmount(user_bnb, migrator.cdpBnbCollateral());
    uint beforeMarketAsset = getMarketAsset(slisBnb_marketId);

    vm.expectRevert("unauthorized");
    migrator.migratePosition(slisBnb_marketParams, true);

    migrator.MOOLAH().setAuthorization(address(migrator), true);
    migrator.migratePosition(slisBnb_marketParams, true);

    // CDP postion should be cleared
    assertEq(getCdpDebt(user_bnb, migrator.cdpBnbCollateral()), 0, "CDP debt should be cleared after migration");
    assertEq(
      getCdpCollateralAmount(user_bnb, migrator.cdpBnbCollateral()),
      0,
      "CDP collateral should be cleared after migration"
    );

    // user's lisUSD balance should be the same after migration since the migrated position is fully collateralized
    uint256 afterLisUSD = IERC20(lisUSD).balanceOf(user_bnb);
    assertEq(afterLisUSD, beforeLisUSD, "User's lisUSD balance should not change after migration");
  }
}

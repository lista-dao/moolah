pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import { BNBProvider } from "../../src/provider/BNBProvider.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";

contract BNBProviderTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  BNBProvider bnbProvider = BNBProvider(payable(0x367384C54756a25340c63057D87eA22d47Fd5701)); // Lista WBNB BNBProvider
  MoolahVault moolahVault; // WBNB Vault
  Moolah moolah;

  address moolahProxy = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C; // MoolahProxy
  address moolahVaultProxy = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0; // MoolahVaultProxy

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;

  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 60541406);

    // Upgrade MoolahVault
    address newImlp = address(new MoolahVault(moolahProxy, WBNB));
    address oldImpl = 0x0E52472cc585F8E28322CA4536eBd7094431C610;
    vm.startPrank(admin);
    UUPSUpgradeable proxy2 = UUPSUpgradeable(moolahVaultProxy);
    proxy2.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(moolahVaultProxy), newImlp);
    vm.stopPrank();
    moolahVault = MoolahVault(moolahVaultProxy);

    // Upgrade Moolah
    newImlp = address(new Moolah());
    oldImpl = 0x0Cc33Db59a51aaC837790dfb8f8Cd07F7f16d779;
    vm.startPrank(admin);
    UUPSUpgradeable proxy3 = UUPSUpgradeable(moolahProxy);
    proxy3.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(moolahProxy), newImlp);
    vm.stopPrank();
    moolah = Moolah(moolahProxy);

    // Upgrade BNBProvider
    newImlp = address(new BNBProvider(moolahProxy, moolahVaultProxy, WBNB));
    vm.startPrank(admin);
    UUPSUpgradeable proxy1 = UUPSUpgradeable(address(bnbProvider));
    proxy1.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(address(bnbProvider)), newImlp);
    vm.stopPrank();

    MarketParams memory param1 = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });

    MarketParams memory param2 = MarketParams({
      loanToken: USD1,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    // Set up Moolah
    vm.startPrank(manager);
    assertEq(moolah.providers(param1.id(), WBNB), address(bnbProvider));
    assertEq(moolah.providers(param2.id(), WBNB), address(bnbProvider));
    vm.stopPrank();

    // Set up MoolahVault
    assertEq(moolahVault.provider(), address(bnbProvider));
  }

  function test_initialize() public {
    assertEq(address(bnbProvider.MOOLAH()), moolahProxy);
    assertEq(address(bnbProvider.MOOLAH_VAULT()), moolahVaultProxy);
    assertEq(address(bnbProvider.TOKEN()), WBNB);

    assertEq(bnbProvider.hasRole(bnbProvider.DEFAULT_ADMIN_ROLE(), admin), true);
    assertEq(bnbProvider.hasRole(bnbProvider.MANAGER(), manager), true);
  }

  function test_deposit() public {
    deal(user, 100 ether);

    uint256 bnbBalanceBefore = user.balance;
    uint256 wbnbBalanceBefore = IERC20(WBNB).balanceOf(moolahProxy);
    vm.startPrank(user);
    uint256 expectShares = moolahVault.convertToShares(1 ether);
    uint256 shares = bnbProvider.deposit{ value: 1 ether }(user);
    assertEq(shares, expectShares);

    assertEq(user.balance, bnbBalanceBefore - 1 ether);
    assertEq(moolahVault.balanceOf(user), expectShares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahVaultProxy), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahProxy), wbnbBalanceBefore + 1 ether);
  }

  function test_mint() public {
    deal(user, 100 ether);

    uint256 bnbBalanceBefore = user.balance;
    uint256 wbnbBalanceBefore = IERC20(WBNB).balanceOf(moolahProxy);
    vm.startPrank(user);
    uint256 expectAsset = moolahVault.previewMint(1 ether);
    uint256 assets = bnbProvider.mint{ value: expectAsset }(1 ether, user);

    assertEq(assets, expectAsset);
    assertEq(user.balance, bnbBalanceBefore - expectAsset);
    assertEq(moolahVault.balanceOf(user), 1 ether);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahProxy), wbnbBalanceBefore + expectAsset);
  }

  function test_mint_excess() public {
    deal(user, 100 ether);

    uint256 bnbBalanceBefore = user.balance;
    uint256 wbnbBalanceBefore = IERC20(WBNB).balanceOf(moolahProxy);
    vm.startPrank(user);
    uint256 expectAsset = moolahVault.previewMint(1 ether);
    uint256 assets = bnbProvider.mint{ value: expectAsset + 1 }(1 ether, user);

    assertEq(assets, expectAsset);
    assertEq(user.balance, bnbBalanceBefore - expectAsset);
    assertEq(moolahVault.balanceOf(user), 1 ether);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahProxy), wbnbBalanceBefore + expectAsset);
  }

  function test_withdraw() public {
    test_deposit();

    skip(1 days);

    vm.startPrank(user);
    uint256 balanceBefore = user.balance;
    uint256 sharesBefore = moolahVault.balanceOf(user);
    uint256 totalAssets = moolahVault.totalAssets();
    uint256 expectShares = moolahVault.convertToShares(1 ether);
    uint256 shares = bnbProvider.withdraw(1 ether, payable(user), user);

    assertApproxEqAbs(shares, expectShares, 1);
    assertEq(moolahVault.balanceOf(user), sharesBefore - shares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(user.balance, balanceBefore + 1 ether);
    assertEq(moolahVault.totalAssets(), totalAssets - 1 ether);
  }

  function test_redeem() public {
    test_deposit();

    skip(1 days);

    vm.startPrank(user);
    uint256 balanceBefore = user.balance;
    uint256 sharesBefore = moolahVault.balanceOf(user);
    uint256 totalAssets = moolahVault.totalAssets();
    uint256 shares = moolahVault.convertToShares(1 ether);
    uint256 assets = bnbProvider.redeem(shares, payable(user), user);

    assertApproxEqAbs(assets, 1 ether, 1);
    assertEq(moolahVault.balanceOf(user), sharesBefore - shares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertApproxEqAbs(user.balance, balanceBefore + 1 ether, 1);
    assertApproxEqAbs(moolahVault.totalAssets(), totalAssets - 1 ether, 1);
  }

  function test_redeem_all() public {
    test_deposit();

    skip(1 days);

    vm.startPrank(user);
    uint256 balanceBefore = user.balance;
    uint256 sharesBefore = moolahVault.balanceOf(user);
    uint256 totalAssets = moolahVault.totalAssets();
    uint256 shares = sharesBefore;
    uint256 expectAssets = moolahVault.convertToAssets(shares);
    uint256 assets = bnbProvider.redeem(shares, payable(user), user);

    assertEq(assets, expectAssets);
    assertEq(moolahVault.balanceOf(user), 0);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(user.balance, balanceBefore + assets);
    assertEq(moolahVault.totalAssets(), totalAssets - assets);
  }

  function test_supplyCollateral() public returns (MarketParams memory) {
    deal(user, 100 ether);

    MarketParams memory param = MarketParams({
      loanToken: USD1,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    uint256 bnbBalanceBefore = user.balance;
    vm.startPrank(user);
    bnbProvider.supplyCollateral{ value: 1 ether }(param, user, "");

    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, 0);
    assertEq(collateral, 1 ether);
    assertEq(user.balance, bnbBalanceBefore - 1 ether);

    return param;
  }

  function test_withdrawCollateral() public {
    MarketParams memory param = test_supplyCollateral();

    uint256 bnbBalanceBefore = user.balance;
    vm.startPrank(user);
    bnbProvider.withdrawCollateral(param, 1 ether, user, payable(user));

    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, 0);
    assertEq(collateral, 0);
    assertEq(user.balance, bnbBalanceBefore + 1 ether);
  }

  function test_withdrawCollateral_onBehalf() public {
    MarketParams memory param = test_supplyCollateral();
    vm.stopPrank();

    uint256 bnbBalanceBefore = user2.balance;
    vm.prank(user);
    moolah.setAuthorization(user2, true);

    vm.startPrank(user2);
    bnbProvider.withdrawCollateral(param, 1 ether, user, payable(user2));

    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, 0);
    assertEq(collateral, 0);
    assertEq(user2.balance, bnbBalanceBefore + 1 ether);
  }

  function test_supplyCollateral_btcb() public returns (MarketParams memory) {
    deal(BTCB, user, 100 ether);

    MarketParams memory param = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });

    uint256 balanceBefore = IERC20(BTCB).balanceOf(user);
    uint256 moolahBalanceBefore = IERC20(BTCB).balanceOf(moolahProxy);
    vm.startPrank(user);
    vm.expectRevert();
    bnbProvider.supplyCollateral{ value: 1 ether }(param, user, "");
    IERC20(BTCB).approve(address(moolah), 1 ether);
    moolah.supplyCollateral(param, 1 ether, user, "");

    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, 0);
    assertEq(collateral, 1 ether);
    assertEq(IERC20(BTCB).balanceOf(moolahProxy), moolahBalanceBefore + 1 ether);
    assertEq(IERC20(BTCB).balanceOf(user), balanceBefore - 1 ether);

    return param;
  }

  function test_borrow() public returns (MarketParams memory) {
    MarketParams memory param = test_supplyCollateral_btcb();

    uint256 balanceBefore = user.balance;
    vm.startPrank(user);
    bnbProvider.borrow(param, 1 ether, 0, user, payable(user));

    uint256 assets = 1 ether;
    (
      uint128 totalSupplyAssets,
      uint128 totalSupplyShares,
      uint128 totalBorrowAssets,
      uint128 totalBorrowShares,
      uint128 lastUpdate,
      uint128 fee
    ) = moolah.market(param.id());

    uint256 shares = assets.toSharesUp(totalBorrowAssets, totalBorrowShares);
    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, shares);
    assertEq(collateral, 1 ether);
    assertEq(user.balance, balanceBefore + assets);

    return param;
  }

  function test_borrow_onBehalf() public returns (MarketParams memory) {
    MarketParams memory param = test_supplyCollateral_btcb();
    vm.stopPrank();

    uint256 balanceBefore = user2.balance;
    vm.prank(user);
    moolah.setAuthorization(user2, true);

    vm.startPrank(user2);
    bnbProvider.borrow(param, 1 ether, 0, user, payable(user2));

    uint256 assets = 1 ether;
    (
      uint128 totalSupplyAssets,
      uint128 totalSupplyShares,
      uint128 totalBorrowAssets,
      uint128 totalBorrowShares,
      uint128 lastUpdate,
      uint128 fee
    ) = moolah.market(param.id());

    uint256 shares = assets.toSharesUp(totalBorrowAssets, totalBorrowShares);
    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, shares);
    assertEq(collateral, 1 ether);
    assertEq(user2.balance, balanceBefore + assets);

    return param;
  }

  function test_repay() public {
    deal(user, 100 ether);
    MarketParams memory param = test_borrow();

    skip(1 days);

    moolah.accrueInterest(param);
    vm.startPrank(user);
    (uint256 supplySharesBefore, uint128 borrowSharesBefore, uint128 collateralBefore) = moolah.position(
      param.id(),
      user
    );
    (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = moolah.market(param.id());
    uint256 assets = uint256(borrowSharesBefore).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    uint256 balanceBefore = user.balance;
    vm.expectRevert("insufficient funds");
    bnbProvider.repay{ value: 0 }(param, 0, borrowSharesBefore, user, "");
    bnbProvider.repay{ value: assets + 100 }(param, 0, borrowSharesBefore, user, "");

    (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = moolah.position(param.id(), user);
    assertEq(supplyShares, 0);
    assertEq(borrowShares, 0);
    assertEq(collateral, 1 ether);
    assertEq(user.balance, balanceBefore - assets);
  }

  function test_addVault() public {
    MoolahVault newVaultImpl = new MoolahVault(moolahProxy, WBNB);
    address newVaultProxy = address(
      new ERC1967Proxy(
        address(newVaultImpl),
        abi.encodeWithSelector(newVaultImpl.initialize.selector, admin, manager, WBNB, "new vault", "new vault")
      )
    );
    vm.startPrank(manager);
    bnbProvider.addVault(newVaultProxy);
    vm.stopPrank();

    assertEq(bnbProvider.vaults(newVaultProxy), true, "add vault failed");
  }

  function test_removeVault() public {
    vm.startPrank(manager);
    bnbProvider.removeVault(moolahVaultProxy);
    vm.stopPrank();

    assertEq(bnbProvider.vaults(moolahVaultProxy), false, "remove vault failed");
  }

  function test_depositNotInVaults() public {
    deal(user, 100 ether);

    vm.startPrank(manager);
    bnbProvider.removeVault(moolahVaultProxy);
    vm.stopPrank();

    vm.startPrank(user);
    vm.expectRevert(bytes("vault not added"));
    bnbProvider.deposit{ value: 1 ether }(moolahVaultProxy, user);

    vm.expectRevert(bytes("vault not added"));
    bnbProvider.mint{ value: 1 ether }(moolahVaultProxy, 1 ether, user);
    vm.stopPrank();
  }

  function test_withdrawNotInVaults() public {
    test_deposit();

    bnbProvider.deposit{ value: 1 ether }(moolahVaultProxy, user);

    vm.startPrank(manager);
    bnbProvider.removeVault(moolahVaultProxy);
    vm.stopPrank();

    vm.startPrank(user);
    vm.expectRevert(bytes("vault not added"));
    bnbProvider.withdraw(moolahVaultProxy, 1 ether, payable(user), user);

    uint256 shares = moolahVault.balanceOf(user);
    vm.expectRevert(bytes("vault not added"));
    bnbProvider.redeem(moolahVaultProxy, shares, payable(user), user);
    vm.stopPrank();
  }

  function test_depositInVaults() public {
    deal(user, 100 ether);

    uint256 bnbBalanceBefore = user.balance;
    uint256 wbnbBalanceBefore = IERC20(WBNB).balanceOf(moolahProxy);
    vm.startPrank(user);
    uint256 expectShares = moolahVault.convertToShares(1 ether);
    uint256 shares = bnbProvider.deposit{ value: 1 ether }(moolahVaultProxy, user);
    assertEq(shares, expectShares);

    assertEq(user.balance, bnbBalanceBefore - 1 ether);
    assertEq(moolahVault.balanceOf(user), expectShares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahVaultProxy), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahProxy), wbnbBalanceBefore + 1 ether);
  }

  function test_mintInVaults() public {
    deal(user, 100 ether);

    uint256 bnbBalanceBefore = user.balance;
    uint256 wbnbBalanceBefore = IERC20(WBNB).balanceOf(moolahProxy);
    vm.startPrank(user);
    uint256 expectAsset = moolahVault.previewMint(1 ether);
    uint256 assets = bnbProvider.mint{ value: expectAsset }(moolahVaultProxy, 1 ether, user);

    assertEq(assets, expectAsset);
    assertEq(user.balance, bnbBalanceBefore - expectAsset);
    assertEq(moolahVault.balanceOf(user), 1 ether);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(IERC20(WBNB).balanceOf(moolahProxy), wbnbBalanceBefore + expectAsset);
  }

  function test_withdrawInVaults() public {
    test_depositInVaults();

    skip(1 days);

    vm.startPrank(user);
    uint256 balanceBefore = user.balance;
    uint256 sharesBefore = moolahVault.balanceOf(user);
    uint256 totalAssets = moolahVault.totalAssets();
    uint256 expectShares = moolahVault.convertToShares(1 ether);
    uint256 shares = bnbProvider.withdraw(moolahVaultProxy, 1 ether, payable(user), user);

    assertApproxEqAbs(shares, expectShares, 1);
    assertEq(moolahVault.balanceOf(user), sharesBefore - shares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertEq(user.balance, balanceBefore + 1 ether);
    assertEq(moolahVault.totalAssets(), totalAssets - 1 ether);
  }

  function test_redeemInVaults() public {
    test_depositInVaults();

    skip(1 days);

    vm.startPrank(user);
    uint256 balanceBefore = user.balance;
    uint256 sharesBefore = moolahVault.balanceOf(user);
    uint256 totalAssets = moolahVault.totalAssets();
    uint256 shares = moolahVault.convertToShares(1 ether);
    uint256 assets = bnbProvider.redeem(moolahVaultProxy, shares, payable(user), user);

    assertApproxEqAbs(assets, 1 ether, 1);
    assertEq(moolahVault.balanceOf(user), sharesBefore - shares);
    assertEq(moolahVault.balanceOf(address(bnbProvider)), 0);
    assertApproxEqAbs(user.balance, balanceBefore + 1 ether, 1);
    assertApproxEqAbs(moolahVault.totalAssets(), totalAssets - 1 ether, 1);
  }

  function getImplementation(address _proxyAddress) public view returns (address) {
    bytes32 implSlot = vm.load(_proxyAddress, IMPLEMENTATION_SLOT);
    return address(uint160(uint256(implSlot)));
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import { CollateralYieldVault } from "../../src/moolah-vault/CollateralYieldVault.sol";
import { SlisBNBProvider } from "../../src/provider/SlisBNBProvider.sol";
import { ISlisBnbProvider } from "../../src/provider/interfaces/IProvider.sol";
import { SlisBNBxMinter, ISlisBNBx } from "../../src/utils/SlisBNBxMinter.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";

interface IStakeManagerLike {
  function deposit() external payable;

  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);
}

contract CollateralYieldVaultTest is Test {
  using MarketParamsLib for MarketParams;

  // --- mainnet addresses ---
  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address providerManager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address slisBnb = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address stakeManager = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address slisBnbx = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
  address slisBnbModule = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f; // SlisBNBProvider
  address slisBnbxOwner = 0x702115D6d3Bbb37F407aae4dEcf9d09980e28ebc;

  // --- vault roles / actors ---
  address vAdmin = makeAddr("vAdmin");
  address vManager = makeAddr("vManager");
  address vPauser = makeAddr("vPauser");
  address bot = makeAddr("bot");
  address feeRecipient = makeAddr("feeRecipient");
  address feeWallet = makeAddr("feeWallet"); // minter MPC fee wallet
  address delegateMpc = makeAddr("delegateMpc"); // launchpool MPC (delegate target)
  address alice = makeAddr("alice");
  address charlie = makeAddr("charlie");

  SlisBNBProvider provider;
  SlisBNBxMinter minter;
  CollateralYieldVault vault;
  MarketParams market; // slisBNB collateral / WBNB loan

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 68721673);

    _setupMinterAndProvider();

    // existing slisBNB-collateral market served by the provider
    market = MarketParams({
      loanToken: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      collateralToken: slisBnb,
      oracle: 0x21650E416dC6C89486B2E654c86cC2c36c597b58,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 965000000000000000
    });

    // deploy vault (asset/stakeManager derived from provider)
    CollateralYieldVault impl = new CollateralYieldVault(slisBnbModule);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        CollateralYieldVault.initialize.selector,
        vAdmin,
        vManager,
        vPauser,
        market,
        "Collateral Yield Vault slisBNB",
        "cySlisBNB"
      )
    );
    vault = CollateralYieldVault(payable(address(proxy)));

    // wire roles + delegate target
    bytes32 botRole = vault.BOT();
    vm.prank(vAdmin);
    vault.grantRole(botRole, bot);

    vm.prank(vManager);
    vault.setDelegateTarget(delegateMpc);

    // sanity: provider-derived immutables
    assertEq(vault.asset(), slisBnb, "asset");
    assertEq(address(vault.STAKE_MANAGER()), stakeManager, "stakeManager");
    assertEq(address(vault.PROVIDER()), slisBnbModule, "provider");
    assertEq(vault.decimals(), 18, "decimals");
  }

  /* ----------------------------- setUp helpers ----------------------------- */

  function _setupMinterAndProvider() internal {
    // fresh minter with the SlisBNBProvider as a module
    SlisBNBxMinter mImpl = new SlisBNBxMinter(slisBnbx);
    address[] memory modules = new address[](1);
    modules[0] = slisBnbModule;
    SlisBNBxMinter.ModuleConfig[] memory cfgs = new SlisBNBxMinter.ModuleConfig[](1);
    cfgs[0] = SlisBNBxMinter.ModuleConfig({ discount: 0, feeRate: 3e4, moduleAddress: slisBnbModule });
    ERC1967Proxy mProxy = new ERC1967Proxy(
      address(mImpl),
      abi.encodeWithSelector(SlisBNBxMinter.initialize.selector, admin, providerManager, modules, cfgs)
    );
    minter = SlisBNBxMinter(address(mProxy));

    vm.prank(providerManager);
    minter.addMPCWallet(feeWallet, 1_000_000_000 ether);

    // upgrade provider impl and point it at the fresh minter
    address newImpl = address(new SlisBNBProvider(address(moolah), slisBnb, stakeManager, slisBnbx));
    vm.prank(admin);
    UUPSUpgradeable(slisBnbModule).upgradeToAndCall(newImpl, "");
    provider = SlisBNBProvider(slisBnbModule);
    vm.prank(providerManager);
    provider.setSlisBNBxMinter(address(minter));

    // authorize the fresh minter to mint slisBNBx
    vm.prank(slisBnbxOwner);
    ISlisBNBx(slisBnbx).addMinter(address(minter));
  }

  function _pps() internal view returns (uint256) {
    // assets returned for 1e18 shares
    return vault.convertToAssets(1e18);
  }

  /* -------------------------------- tests ---------------------------------- */

  function test_depositBNB_mintsSharesAndDelegates() public {
    uint256 amount = 10 ether;
    deal(alice, amount);

    uint256 mpcBefore = ISlisBNBx(slisBnbx).balanceOf(delegateMpc);

    vm.prank(alice);
    uint256 shares = vault.depositBNB{ value: amount }(alice);

    uint256 staked = IStakeManagerLike(stakeManager).convertBnbToSnBnb(amount);
    assertApproxEqAbs(vault.totalAssets(), staked, 2, "totalAssets == staked slisBNB");
    assertEq(provider.userTotalDeposit(address(vault)), vault.totalAssets(), "provider position == totalAssets");
    assertEq(shares, vault.balanceOf(alice), "alice shares");
    assertApproxEqAbs(shares, staked, 2, "first deposit shares ~= assets");

    // slisBNBx delegated to the MPC (minus the minter fee portion)
    assertEq(minter.delegation(address(vault)), delegateMpc, "delegation target");
    assertGt(ISlisBNBx(slisBnbx).balanceOf(delegateMpc) - mpcBefore, 0, "slisBNBx to MPC");
  }

  function test_deposit_slisBNB() public {
    uint256 amount = 8 ether;
    deal(slisBnb, alice, amount);

    vm.startPrank(alice);
    IERC20(slisBnb).approve(address(vault), amount);
    uint256 shares = vault.deposit(amount, alice);
    vm.stopPrank();

    assertEq(shares, amount, "first deposit shares == assets");
    assertEq(vault.totalAssets(), amount, "totalAssets");
    assertEq(provider.userTotalDeposit(address(vault)), amount, "provider position");
  }

  function test_redeem_returnsSlisBNB() public {
    uint256 amount = 8 ether;
    deal(slisBnb, alice, amount);
    vm.startPrank(alice);
    IERC20(slisBnb).approve(address(vault), amount);
    uint256 shares = vault.deposit(amount, alice);

    uint256 balBefore = IERC20(slisBnb).balanceOf(alice);
    uint256 assets = vault.redeem(shares, alice, alice);
    vm.stopPrank();

    assertApproxEqAbs(assets, amount, 2, "assets out ~= deposit");
    assertEq(IERC20(slisBnb).balanceOf(alice) - balBefore, assets, "slisBNB received");
    assertEq(vault.balanceOf(alice), 0, "shares burned");
    assertApproxEqAbs(vault.totalAssets(), 0, 2, "position drained");
  }

  function test_increaseVaultAssets_feeZero_raisesPriceNoShares() public {
    // alice seeds the vault
    _deposit(alice, 100 ether);

    uint256 ppsBefore = _pps();
    uint256 supplyBefore = vault.totalSupply();
    uint256 assetsBefore = vault.totalAssets();
    uint256 aliceRedeemBefore = vault.convertToAssets(vault.balanceOf(alice));

    // bot injects 10 BNB of launchpool reward
    uint256 reward = 10 ether;
    deal(bot, reward);
    vm.prank(bot);
    vault.increaseVaultAssets{ value: reward }();

    uint256 staked = IStakeManagerLike(stakeManager).convertBnbToSnBnb(reward);

    assertEq(vault.totalSupply(), supplyBefore, "no shares minted (fee=0)");
    assertApproxEqAbs(vault.totalAssets(), assetsBefore + staked, 2, "totalAssets += reward");
    assertGt(_pps(), ppsBefore, "pricePerShare up");
    assertApproxEqAbs(
      vault.convertToAssets(vault.balanceOf(alice)),
      aliceRedeemBefore + staked,
      3,
      "alice redeemable += full reward"
    );
  }

  function test_increaseVaultAssets_feeOn_chargesFeeOnIncrement() public {
    _deposit(alice, 100 ether);

    // enable 10% performance fee
    vm.startPrank(vManager);
    vault.setFeeRecipient(feeRecipient);
    vault.setFee(0.1e18);
    vm.stopPrank();

    uint256 reward = 10 ether;
    deal(bot, reward);
    vm.prank(bot);
    vault.increaseVaultAssets{ value: reward }();

    uint256 staked = IStakeManagerLike(stakeManager).convertBnbToSnBnb(reward);
    uint256 feeShares = vault.balanceOf(feeRecipient);
    assertGt(feeShares, 0, "fee shares minted");
    // feeRecipient's asset value ~= 10% of the reward increment
    assertApproxEqRel(vault.convertToAssets(feeShares), staked / 10, 0.02e18, "fee ~= 10% of increment");
  }

  function test_userWhitelist_gatesDepositAndTransfer() public {
    // enable whitelist with only alice
    vm.prank(vManager);
    vault.setWhiteList(alice, true);

    // charlie (not whitelisted) cannot deposit
    deal(slisBnb, charlie, 1 ether);
    vm.startPrank(charlie);
    IERC20(slisBnb).approve(address(vault), 1 ether);
    vm.expectRevert();
    vault.deposit(1 ether, charlie);
    vm.stopPrank();

    // alice can deposit
    _deposit(alice, 5 ether);

    // alice cannot transfer shares to non-whitelisted charlie
    vm.prank(alice);
    vm.expectRevert();
    vault.transfer(charlie, 1 ether);

    // after whitelisting charlie, transfer succeeds
    vm.prank(vManager);
    vault.setWhiteList(charlie, true);
    vm.prank(alice);
    vault.transfer(charlie, 1 ether);
    assertEq(vault.balanceOf(charlie), 1 ether, "transfer ok after whitelist");
  }

  function test_setDelegateTarget_managerOnly_andUpdatesMinter() public {
    address newMpc = makeAddr("newMpc");

    // non-manager cannot set
    vm.prank(alice);
    vm.expectRevert();
    vault.setDelegateTarget(newMpc);

    // zero address rejected
    vm.prank(vManager);
    vm.expectRevert(); // ErrorsLib.ZeroAddress
    vault.setDelegateTarget(address(0));

    // manager can set any non-zero target; minter delegation follows
    vm.prank(vManager);
    vault.setDelegateTarget(newMpc);
    assertEq(vault.delegateTarget(), newMpc, "delegate target updated");
    assertEq(minter.delegation(address(vault)), newMpc, "minter delegation updated");
  }

  function test_emergencyWithdraw_recoversStrayTokens() public {
    _deposit(alice, 50 ether);
    uint256 navBefore = vault.totalAssets();

    // a stray slisBNB transfer lands idle in the vault (not in the position, not in NAV)
    deal(slisBnb, address(vault), 3 ether);
    assertEq(vault.totalAssets(), navBefore, "stray balance not counted in NAV");

    // non-manager cannot withdraw
    vm.prank(alice);
    vm.expectRevert();
    vault.emergencyWithdraw(3 ether, slisBnb);

    // manager recovers the stray tokens; NAV and position unaffected
    uint256 mgrBefore = IERC20(slisBnb).balanceOf(vManager);
    vm.prank(vManager);
    vault.emergencyWithdraw(3 ether, slisBnb);

    assertEq(IERC20(slisBnb).balanceOf(vManager) - mgrBefore, 3 ether, "stray slisBNB recovered to manager");
    assertEq(vault.totalAssets(), navBefore, "NAV unchanged");
  }

  function test_pause_blocksDepositNotRedeem() public {
    _deposit(alice, 10 ether);

    vm.prank(vPauser);
    vault.pause();

    deal(slisBnb, alice, 1 ether);
    vm.startPrank(alice);
    IERC20(slisBnb).approve(address(vault), 1 ether);
    vm.expectRevert();
    vault.deposit(1 ether, alice);
    // redeem still works while paused
    uint256 out = vault.redeem(vault.balanceOf(alice), alice, alice);
    vm.stopPrank();
    assertGt(out, 0, "redeem allowed while paused");
  }

  function test_increaseVaultAssets_onlyBot() public {
    deal(alice, 1 ether);
    vm.prank(alice);
    vm.expectRevert();
    vault.increaseVaultAssets{ value: 1 ether }();
  }

  function test_donation_onlyViaProvider_raisesNavAndMintsSlisBNBx() public {
    _deposit(alice, 50 ether);
    uint256 ppsBefore = _pps();
    uint256 mpcBefore = ISlisBNBx(slisBnbx).balanceOf(delegateMpc);

    uint256 donation = 5 ether;
    deal(slisBnb, charlie, donation);

    // (1) a raw Moolah call cannot donate: the market has a provider => msg.sender must be the provider.
    vm.startPrank(charlie);
    IERC20(slisBnb).approve(address(moolah), donation);
    vm.expectRevert();
    moolah.supplyCollateral(market, donation, address(vault), "");

    // (2) the only path is via the provider; this also mints slisBNBx to the vault's delegatee (launchpool).
    IERC20(slisBnb).approve(address(provider), donation);
    provider.supplyCollateral(market, donation, address(vault), "");
    vm.stopPrank();

    assertEq(provider.userTotalDeposit(address(vault)), 55 ether, "donation counted in position");
    assertGt(_pps(), ppsBefore, "donation raises pricePerShare");
    assertGt(ISlisBNBx(slisBnbx).balanceOf(delegateMpc) - mpcBefore, 0, "donation also mints slisBNBx to MPC");
  }

  function test_sweep_recoversDustOnlyWhenEmpty() public {
    address treasury = makeAddr("treasury");
    uint256 shares = _deposit(alice, 100 ether);

    // compound so pricePerShare > 1 => redeem rounding will leave dust
    uint256 reward = 10 ether;
    deal(bot, reward);
    vm.prank(bot);
    vault.increaseVaultAssets{ value: reward }();

    // sweep is blocked while shares are outstanding
    vm.prank(vManager);
    vm.expectRevert(CollateralYieldVault.SharesOutstanding.selector);
    vault.sweep(treasury);

    // alice redeems everything -> floor rounding leaves dust in the position
    vm.prank(alice);
    vault.redeem(shares, alice, alice);

    uint256 dust = provider.userTotalDeposit(address(vault));
    assertEq(vault.totalSupply(), 0, "no shares left");
    assertGt(dust, 0, "dust remains");
    assertEq(vault.totalAssets(), dust, "totalAssets == dust");

    // only MANAGER can sweep
    vm.prank(alice);
    vm.expectRevert();
    vault.sweep(treasury);

    vm.prank(vManager);
    uint256 swept = vault.sweep(treasury);

    assertEq(swept, dust, "swept == dust");
    assertEq(IERC20(slisBnb).balanceOf(treasury), dust, "dust to treasury");
    assertEq(provider.userTotalDeposit(address(vault)), 0, "position cleared");
    assertEq(vault.totalAssets(), 0, "clean empty state");
  }

  /* -------------------------------- utils ---------------------------------- */

  function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
    deal(slisBnb, user, amount);
    vm.startPrank(user);
    IERC20(slisBnb).approve(address(vault), amount);
    shares = vault.deposit(amount, user);
    vm.stopPrank();
  }
}

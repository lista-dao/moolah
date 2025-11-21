pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import { SlisBNBxMinter, ISlisBNBx } from "../../src/utils/SlisBNBxMinter.sol";

import { SlisBNBProvider, IStakeManager } from "../../src/provider/SlisBNBProvider.sol";
import { SmartProvider } from "../../src/provider/SmartProvider.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";

contract SlisBNBxMinterTest is Test {
  using MarketParamsLib for MarketParams;

  SlisBNBxMinter minter;

  address mpc = makeAddr("mpc");

  address user1 = makeAddr("user1");
  address user2 = makeAddr("user2");
  address delegatee = makeAddr("delegatee");

  address smartLpModule = 0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE;
  address slisBnbModule = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;

  SlisBNBProvider slisBnbProvider;
  SmartProvider smartProvider;

  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address slisBnb = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address stakeManager = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address slisBnbx = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;

  MarketParams param1; // smart lp, usd1
  MarketParams param2; // smart lp, bnb
  MarketParams param3; // slisBnb, bnb

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 68721673);

    SlisBNBxMinter _impl = new SlisBNBxMinter(slisBnbx);
    address[] memory modules = new address[](2);
    modules[0] = slisBnbModule;
    modules[1] = smartLpModule;

    SlisBNBxMinter.ModuleConfig[] memory moduleConfigs = new SlisBNBxMinter.ModuleConfig[](2);
    moduleConfigs[0] = SlisBNBxMinter.ModuleConfig({
      discount: 0,
      feeRate: 3e4, // 3%
      enabled: true
    });
    moduleConfigs[1] = SlisBNBxMinter.ModuleConfig({
      discount: 2e4, // 2%
      feeRate: 3e4, // 3%
      enabled: true
    });

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(_impl),
      abi.encodeWithSelector(SlisBNBxMinter.initialize.selector, admin, manager, modules, moduleConfigs)
    );

    minter = SlisBNBxMinter(address(proxy));

    assertTrue(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(minter.hasRole(minter.MANAGER(), manager));

    (uint24 discount, uint24 feeRate, bool enabled) = minter.moduleConfig(slisBnbModule);
    assertEq(discount, 0);
    assertEq(feeRate, 3e4);
    assertTrue(enabled);

    (discount, feeRate, enabled) = minter.moduleConfig(smartLpModule);
    assertEq(discount, 2e4);
    assertEq(feeRate, 3e4);
    assertTrue(enabled);

    // add MPC
    vm.prank(manager);
    minter.addMPCWallet(mpc, 1_000_000_000 ether);

    // upgrade slisBnb provider
    upgrade_SlisBNBProvider();

    // upgrade smart provider
    upgrade_SmartProvider();

    // set minter to slisBNBx
    vm.prank(0x702115D6d3Bbb37F407aae4dEcf9d09980e28ebc);
    ISlisBNBx(slisBnbx).addMinter(address(minter));

    // init market params
    set_market_params();
  }

  function upgrade_SlisBNBProvider() public {
    slisBnbProvider = SlisBNBProvider(slisBnbModule);
    // delegate
    address user = 0xFF051b7B20eC819C6785FaA369D99bc2C9235B8a;
    vm.prank(user);
    slisBnbProvider.delegateAllTo(delegatee);

    address newImlp = address(new SlisBNBProvider(address(moolah), slisBnb, stakeManager, slisBnbx));
    vm.startPrank(admin);
    UUPSUpgradeable proxy = UUPSUpgradeable(slisBnbModule);
    proxy.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(slisBnbModule), newImlp);
    vm.stopPrank();
    slisBnbProvider = SlisBNBProvider(slisBnbModule);

    vm.prank(manager);
    slisBnbProvider.setSlisBNBxMinter(address(minter));
    assertEq(slisBnbProvider.slisBNBxMinter(), address(minter));
  }

  function upgrade_SmartProvider() public {
    address lpCollateral = 0x719f6445cdAC08B84611D0F19d733F57214bcfee;
    address newImlp = address(new SmartProvider(address(moolah), lpCollateral));
    vm.startPrank(admin);
    UUPSUpgradeable proxy = UUPSUpgradeable(smartLpModule);
    proxy.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(smartLpModule), newImlp);
    vm.stopPrank();
    smartProvider = SmartProvider(payable(smartLpModule));

    vm.startPrank(admin);
    smartProvider.grantRole(smartProvider.MANAGER(), manager);
    vm.stopPrank();

    vm.prank(manager);
    smartProvider.setSlisBNBxMinter(address(minter));
    assertEq(smartProvider.slisBNBxMinter(), address(minter));
  }

  function set_market_params() public {
    param1 = MarketParams({
      loanToken: 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d,
      collateralToken: 0x719f6445cdAC08B84611D0F19d733F57214bcfee,
      oracle: smartLpModule,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 75 * 1e16
    });
    param2 = MarketParams({
      loanToken: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      collateralToken: 0x719f6445cdAC08B84611D0F19d733F57214bcfee,
      oracle: smartLpModule,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 915 * 1e15
    });
    param3 = MarketParams({
      loanToken: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      collateralToken: slisBnb,
      oracle: 0x21650E416dC6C89486B2E654c86cC2c36c597b58,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 965000000000000000
    });
  }

  function test_smart_lp_module_new_user() public {
    uint256 amount = 10 ether;
    deal(user1, amount);
    deal(slisBnb, user1, amount);

    vm.startPrank(user1);
    IERC20(slisBnb).approve(address(smartProvider), amount);
    uint256 slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user1);
    smartProvider.supplyCollateral{ value: amount }(param1, user1, amount, amount, 0);

    slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user1) - slisBnbxMinted;

    (, , uint128 stakedSmartLp) = moolah.position(param1.id(), user1);
    assertEq(stakedSmartLp, smartProvider.userTotalDeposit(user1), "collateral amount error");
    assertEq(stakedSmartLp, smartProvider.userMarketDeposit(user1, param1.id()), "market collateral amount error");

    // check slisBNBx minted with discount and fee
    uint256 collateralInBnb = smartProvider.getUserBalanceInBnb(user1);
    uint256 expectMinted = (collateralInBnb * (1e6 - 2e4)) / 1e6; // 2% discount
    uint256 fee = (expectMinted * 3e4) / 1e6; // 3% fee
    expectMinted = expectMinted - fee;
    assertEq(slisBnbxMinted, expectMinted, "slisBNBx minted error");

    // check fee receiver balance
    uint256 actualFee = ISlisBNBx(slisBnbx).balanceOf(mpc);
    assertEq(actualFee, fee, "fee receiver balance error");

    // check balaces in minter
    (uint256 userPart, uint256 feePart) = minter.userModuleBalance(user1, smartLpModule);
    assertEq(userPart, expectMinted, "user part error");
    assertEq(feePart, fee, "fee part error");
    assertEq(minter.userTotalBalance(user1), userPart, "user1 total balance error");
  }

  function test_slisBnb_module_new_user() public {
    uint256 amount = 10 ether;
    deal(slisBnb, user2, amount);

    vm.startPrank(user2);
    IERC20(slisBnb).approve(address(slisBnbProvider), amount);
    uint256 slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user2);
    slisBnbProvider.supplyCollateral(param3, amount, user2, "");

    slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user2) - slisBnbxMinted;

    (, , uint128 stakedSlisBnb) = moolah.position(param3.id(), user2);
    assertEq(stakedSlisBnb, slisBnbProvider.userTotalDeposit(user2), "collateral amount error");
    assertEq(stakedSlisBnb, slisBnbProvider.userMarketDeposit(user2, param3.id()), "market collateral amount error");

    // check slisBNBx minted with no discount and fee
    uint256 collateralInBnb = slisBnbProvider.getUserBalanceInBnb(user2);
    uint256 expectMinted = collateralInBnb; // no discount
    uint256 fee = (expectMinted * 3e4) / 1e6; // 3% fee
    expectMinted = expectMinted - fee;
    assertEq(slisBnbxMinted, expectMinted, "slisBNBx minted error");

    // check fee receiver balance
    uint256 actualFee = ISlisBNBx(slisBnbx).balanceOf(mpc);
    assertEq(actualFee, fee, "fee receiver balance error");

    // check balaces in minter
    (uint256 userPart, uint256 feePart) = minter.userModuleBalance(user2, slisBnbModule);
    assertEq(userPart, expectMinted, "user part error");
    assertEq(feePart, fee, "fee part error");
    assertEq(minter.userTotalBalance(user2), userPart, "user2 total balance error");
  }

  function test_slisBnb_module_old_user_one_market() public {
    address user = 0x8833Dfd3cf3b2b7b515cD15D33A4378fB2c31160;
    // sync user position
    slisBnbProvider.syncUserLp(param3.id(), user);
    (, , uint128 stakedSlisBnb) = moolah.position(param3.id(), user);
    assertEq(slisBnbProvider.userMarketDeposit(user, param3.id()), stakedSlisBnb);
    assertEq(slisBnbProvider.userTotalDeposit(user), stakedSlisBnb);

    uint256 amount = 5 ether;
    deal(slisBnb, user, amount);
    uint256 slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user);
    vm.startPrank(user);
    IERC20(slisBnb).approve(address(slisBnbProvider), amount);
    slisBnbProvider.supplyCollateral(param3, amount, user, "");
    slisBnbxMinted = ISlisBNBx(slisBnbx).balanceOf(user) - slisBnbxMinted;

    (, , stakedSlisBnb) = moolah.position(param3.id(), user);
    assertEq(stakedSlisBnb, slisBnbProvider.userTotalDeposit(user), "collateral amount error"); // only one market supply
    assertEq(stakedSlisBnb, slisBnbProvider.userMarketDeposit(user, param3.id()), "market collateral amount error");

    // check slisBNBx minted with no discount and fee
    uint256 collateralInBnb = slisBnbProvider.getUserBalanceInBnb(user); // total slisBnbx with no discount
    uint256 expectMinted = collateralInBnb; // no discount

    // check slisBNBx total supply; TODO: how to check total supply change
    uint256 totalSupply = ISlisBNBx(slisBnbx).totalSupply();
    // assertEq(totalSupply, totalSupplyBefore + expectMinted, "slisBNBx total supply error");

    uint256 fee = (expectMinted * 3e4) / 1e6; // 3% fee
    expectMinted = expectMinted - fee;
    assertEq(ISlisBNBx(slisBnbx).balanceOf(user), expectMinted, "slisBNBx minted error");

    // check fee receiver balance
    uint256 actualFee = ISlisBNBx(slisBnbx).balanceOf(mpc);
    assertEq(actualFee, fee, "fee receiver balance error");

    // check balaces in minter
    (uint256 userPart, uint256 feePart) = minter.userModuleBalance(user, slisBnbModule);
    assertEq(userPart, expectMinted, "user part error");
    assertEq(feePart, fee, "fee part error");
    assertEq(minter.userTotalBalance(user), userPart, "user total balance error");

    // check old data is empty
    assertEq(slisBnbProvider.userReservedLp(user), 0, "old userReservedLp should be zero");
    assertEq(slisBnbProvider.userLp(user), 0, "old userReservedLp should be zero");
  }

  function test_slisBnb_module_old_user_multi_markets() public {
    address user = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
    (, , uint128 stakedSlisBnb) = moolah.position(param3.id(), user);
    assertEq(slisBnbProvider.userMarketDeposit(user, param3.id()), stakedSlisBnb);
    uint256 beforeTotalDeposit = slisBnbProvider.userTotalDeposit(user);
    assertGt(beforeTotalDeposit, stakedSlisBnb);

    uint256 otherBal = ISlisBNBx(slisBnbx).balanceOf(user) - slisBnbProvider.userLp(user);
    uint256 beforeCollateralInBnb = slisBnbProvider.getUserBalanceInBnb(user);

    console.log("user slisBNBx bal:", ISlisBNBx(slisBnbx).balanceOf(user)); // 0.29492327246804595
    console.log("module user LP:", slisBnbProvider.userLp(user)); // 0.20960138248401486
    console.log("module market user deposit:", slisBnbProvider.userMarketDeposit(user, param3.id())); // 0.09259641
    console.log("other module balance:", otherBal); // 0.0853218899840311

    uint256 amount = 5 ether;
    deal(slisBnb, user, amount);
    vm.startPrank(user);
    IERC20(slisBnb).approve(address(slisBnbProvider), amount);
    slisBnbProvider.supplyCollateral(param3, amount, user, "");

    console.log("2. user slisBNBx bal:", ISlisBNBx(slisBnbx).balanceOf(user)); // 5.5162050269490654
    console.log("2. module user LP:", slisBnbProvider.userLp(user)); // 0
    console.log("2. module market user deposit:", slisBnbProvider.userMarketDeposit(user, param3.id())); // before + 5 ether
    (uint256 userPart, uint256 feePart) = minter.userModuleBalance(user, slisBnbModule);
    console.log("2. new contract module balance:", userPart); // 5.221281754481019

    // new total = last total + amount
    assertEq(slisBnbProvider.userTotalDeposit(user), beforeTotalDeposit + uint128(amount), "total deposit error");
    assertEq(
      slisBnbProvider.userMarketDeposit(user, param3.id()),
      stakedSlisBnb + uint128(amount),
      "market deposit error"
    );
    (, , stakedSlisBnb) = moolah.position(param3.id(), user);
    assertEq(stakedSlisBnb, slisBnbProvider.userMarketDeposit(user, param3.id()), "market collateral amount error");

    // check slisBNBx minted with no discount and fee
    uint256 collateralInBnb = slisBnbProvider.getUserBalanceInBnb(user); // total slisBnbx with no discount
    uint256 increaseInBnb = IStakeManager(stakeManager).convertSnBnbToBnb(amount);
    console.log("increaseInBnb: ", increaseInBnb);
    //    assertEq(collateralInBnb, beforeCollateralInBnb + increaseInBnb, "collateral in BNB error");
    uint256 expectMinted = collateralInBnb; // no discount

    // check slisBNBx total supply; TODO: how to check total supply change

    uint256 fee = (expectMinted * 3e4) / 1e6; // 3% fee
    expectMinted = expectMinted - fee;

    // check fee
    uint256 actualFee = ISlisBNBx(slisBnbx).balanceOf(mpc);
    assertEq(actualFee, fee, "fee receiver balance error");

    // check balance and fee in minter
    assertEq(userPart, expectMinted, "user part error");
    assertEq(feePart, fee, "fee part error");
    assertEq(minter.userTotalBalance(user), userPart, "user total balance error");

    // check old data is empty
    assertEq(slisBnbProvider.userReservedLp(user), 0, "old userReservedLp should be zero");
    assertEq(slisBnbProvider.userLp(user), 0, "old userReservedLp should be zero");
  }

  function test_delegatee_sync() public {
    address user = makeAddr("user");
    address delegatee1 = makeAddr("delegatee1");
    address delegatee2 = makeAddr("delegatee2");

    // supply collateral via smart provider
    uint256 amount = 10 ether;
    deal(user, amount);
    deal(slisBnb, user, amount);

    vm.startPrank(user);
    IERC20(slisBnb).approve(address(smartProvider), amount);
    smartProvider.supplyCollateral{ value: amount }(param1, user, amount, amount, 0);
    vm.stopPrank();

    // sync delegatee to delegatee1
    vm.prank(smartLpModule);
    minter.syncDelegatee(user, delegatee1);
    assertEq(minter.delegation(user), delegatee1, "delegatee sync error");

    // sync delegatee to delegatee2
    vm.prank(smartLpModule);
    minter.syncDelegatee(user, delegatee2);
    assertEq(minter.delegation(user), delegatee2, "delegatee sync error");
  }

  function test_delegation_transition() public {
    address user = 0xFF051b7B20eC819C6785FaA369D99bc2C9235B8a;
    assertEq(delegatee, slisBnbProvider.delegation(user), "pre delegatee error");

    uint256 userBefore = ISlisBNBx(slisBnbx).balanceOf(user);
    uint256 delegateeBefore = ISlisBNBx(slisBnbx).balanceOf(delegatee);

    uint256 amount = 5 ether;
    deal(slisBnb, user, amount);
    vm.startPrank(user);
    IERC20(slisBnb).approve(address(slisBnbProvider), amount);
    slisBnbProvider.supplyCollateral(param3, amount, user, "");
    vm.stopPrank();

    // delegation data should be emptied in slisBnbProvider
    assertEq(slisBnbProvider.delegation(user), delegatee, "old provider delegatee should be same");
    assertEq(slisBnbProvider.userLp(delegatee), 0, "old provider delegatee balance should be zero");
    assertEq(slisBnbProvider.userReservedLp(delegatee), 0, "old provider delegatee reserved balance should be zero");

    // delegation data should be set in minter
    assertEq(minter.delegation(user), delegatee, "minter delegation error");
    (uint256 userPart, uint256 feePart) = minter.userModuleBalance(user, slisBnbModule);

    // check slisBNBx minted with no discount and fee
    uint256 collateralInBnb = slisBnbProvider.getUserBalanceInBnb(user); // total slisBnbx with no discount
    uint256 increaseInBnb = IStakeManager(stakeManager).convertSnBnbToBnb(amount);
    uint256 expectMinted = collateralInBnb; // no discount
    uint256 fee = (expectMinted * 3e4) / 1e6; // 3% fee
    expectMinted = expectMinted - fee;

    // check fee
    uint256 actualFee = ISlisBNBx(slisBnbx).balanceOf(mpc);
    assertEq(actualFee, fee, "fee receiver balance error");

    // check owner balance and fee in minter
    assertEq(userPart, expectMinted, "user part error");
    assertEq(feePart, fee, "fee part error");
    assertEq(minter.userTotalBalance(user), userPart, "user total balance error");

    // check delegate balance and fee in minter. should be zero
    (userPart, feePart) = minter.userModuleBalance(delegatee, slisBnbModule);
    assertEq(userPart, 0, "delegatee user part should be zero");
    assertEq(feePart, 0, "delegatee fee part should be zero");

    // check old data is empty
    assertEq(slisBnbProvider.userReservedLp(user), 0, "old userReservedLp should be zero");
    assertEq(slisBnbProvider.userLp(user), 0, "old userReservedLp should be zero");

    // check user balance
    uint256 userAfter = ISlisBNBx(slisBnbx).balanceOf(user);
    assertEq(userAfter - userBefore, 0, "user balance should not change");
  }

  function test_delegateAllTo_no_position() public {
    address user = makeAddr("newUser");
    address delegateeAddr = makeAddr("newDelegatee");

    vm.startPrank(user);
    minter.delegateAllTo(delegateeAddr);
    vm.expectRevert("newDelegatee cannot be zero address or same as current delegatee");
    minter.delegateAllTo(delegateeAddr);
    vm.stopPrank();
  }

  function test_delegateAllTo_with_position() public {
    address user = makeAddr("newUser");
    address delegateeAddr = makeAddr("newDelegatee");

    deal(slisBnb, user, 1 ether);
    deal(smartProvider.dexLP(), user, 1 ether);

    // user supply via slisBnbProvider and smartProvider
    vm.startPrank(user);
    IERC20(slisBnb).approve(address(slisBnbProvider), 1 ether);
    slisBnbProvider.supplyCollateral(param3, 1 ether, user, "");
    IERC20(smartProvider.dexLP()).approve(address(smartProvider), 1 ether);
    smartProvider.supplyDexLp(param1, user, 1 ether);
    vm.stopPrank();

    // check balances in minter
    (uint256 userPart1, ) = minter.userModuleBalance(user, slisBnbModule);
    (uint256 userPart2, ) = minter.userModuleBalance(user, smartLpModule);
    uint256 totalBalance = minter.userTotalBalance(user);

    // delegate
    uint256 beforeUserBalance = ISlisBNBx(slisBnbx).balanceOf(user);
    uint256 beforeDelegateeBalance = ISlisBNBx(slisBnbx).balanceOf(delegateeAddr);
    vm.startPrank(user);
    minter.delegateAllTo(delegateeAddr);
    vm.stopPrank();

    assertEq(minter.delegation(user), delegateeAddr, "delegatee not set");
    (uint256 newUserPart1, ) = minter.userModuleBalance(user, slisBnbModule);
    (uint256 newUserPart2, ) = minter.userModuleBalance(user, smartLpModule);
    uint256 newTotalBalance = minter.userTotalBalance(user);
    assertEq(newUserPart1, userPart1, "user part in slisBnbModule should not change");
    assertEq(newUserPart2, userPart2, "user part in smartLpModule should not change");
    assertEq(newTotalBalance, totalBalance, "total balance should not change");

    // slisBNBx should be moved to delegatee
    uint256 afterUserBalance = ISlisBNBx(slisBnbx).balanceOf(user);
    uint256 afterDelegateeBalance = ISlisBNBx(slisBnbx).balanceOf(delegateeAddr);
    assertEq(afterUserBalance, beforeUserBalance - totalBalance, "user balance not decreased correctly");
    assertEq(afterDelegateeBalance, beforeDelegateeBalance + totalBalance, "delegatee balance not increased correctly");
    assertEq(afterDelegateeBalance, beforeUserBalance, "delegatee balance not equal to before user balance");
  }

  function getImplementation(address _proxyAddress) public view returns (address) {
    bytes32 IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 implSlot = vm.load(_proxyAddress, IMPLEMENTATION_SLOT);
    return address(uint160(uint256(implSlot)));
  }
}

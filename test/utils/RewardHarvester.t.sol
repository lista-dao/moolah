// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MarketParams } from "moolah/interfaces/IMoolah.sol";

import { CollateralYieldVault } from "../../src/moolah-vault/CollateralYieldVault.sol";
import { SlisBNBProvider } from "../../src/provider/SlisBNBProvider.sol";
import { SlisBNBxMinter, ISlisBNBx } from "../../src/utils/SlisBNBxMinter.sol";
import { RewardHarvester } from "../../src/utils/RewardHarvester.sol";

interface IStakeManagerLike {
  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);
}

/// @dev Stand-in for ClisBNBLaunchPoolDistributor: on `claim` it pays `amount` BNB to `_account` (token == BNB).
contract MockLaunchPoolDistributor {
  mapping(uint64 => mapping(address => bool)) public claimed;
  address public lastClaimAccount;
  uint256 public lastClaimAmount;

  function claim(uint64 epochId, address account, uint256 amount, bytes32[] calldata) external {
    require(!claimed[epochId][account], "already claimed");
    claimed[epochId][account] = true;
    lastClaimAccount = account;
    lastClaimAmount = amount;
    (bool ok, ) = payable(account).call{ value: amount }("");
    require(ok, "pay failed");
  }

  receive() external payable {}
}

contract RewardHarvesterTest is Test {
  // mainnet addresses (same wiring as CollateralYieldVault.t.sol)
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address providerManager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address slisBnb = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address stakeManager = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address slisBnbx = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
  address slisBnbModule = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;
  address slisBnbxOwner = 0x702115D6d3Bbb37F407aae4dEcf9d09980e28ebc;

  address vAdmin = makeAddr("vAdmin");
  address vManager = makeAddr("vManager");
  address vPauser = makeAddr("vPauser");
  address hAdmin = makeAddr("hAdmin");
  address hManager = makeAddr("hManager");
  address bot = makeAddr("bot");
  address feeWallet = makeAddr("feeWallet");
  address delegateMpc = makeAddr("delegateMpc");
  address alice = makeAddr("alice");

  SlisBNBProvider provider;
  SlisBNBxMinter minter;
  CollateralYieldVault vault;
  RewardHarvester harvester;
  MockLaunchPoolDistributor distributor;
  MarketParams market;

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), 68721673);

    // minter + provider wiring
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

    address newImpl = address(new SlisBNBProvider(moolah, slisBnb, stakeManager, slisBnbx));
    vm.prank(admin);
    UUPSUpgradeable(slisBnbModule).upgradeToAndCall(newImpl, "");
    provider = SlisBNBProvider(slisBnbModule);
    vm.prank(providerManager);
    provider.setSlisBNBxMinter(address(minter));
    vm.prank(slisBnbxOwner);
    ISlisBNBx(slisBnbx).addMinter(address(minter));

    market = MarketParams({
      loanToken: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      collateralToken: slisBnb,
      oracle: 0x21650E416dC6C89486B2E654c86cC2c36c597b58,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 965000000000000000
    });

    // vault
    CollateralYieldVault vImpl = new CollateralYieldVault(slisBnbModule);
    ERC1967Proxy vProxy = new ERC1967Proxy(
      address(vImpl),
      abi.encodeWithSelector(CollateralYieldVault.initialize.selector, vAdmin, vManager, vPauser, market, "CYV", "CYV")
    );
    vault = CollateralYieldVault(payable(address(vProxy)));

    // harvester (mock distributor)
    distributor = new MockLaunchPoolDistributor();
    RewardHarvester hImpl = new RewardHarvester(address(distributor), address(vault));
    ERC1967Proxy hProxy = new ERC1967Proxy(
      address(hImpl),
      abi.encodeWithSelector(RewardHarvester.initialize.selector, hAdmin, hManager, bot)
    );
    harvester = RewardHarvester(payable(address(hProxy)));

    // vAdmin config: delegate whitelist + grant the harvester the vault BOT role
    bytes32 botRole = vault.BOT();
    vm.startPrank(vAdmin);
    vault.addDelegateTarget(delegateMpc);
    vault.grantRole(botRole, address(harvester));
    vm.stopPrank();
    vm.prank(vManager);
    vault.setDelegateTarget(delegateMpc);

    // fund the distributor with BNB to pay claims
    vm.deal(address(distributor), 100 ether);
  }

  function _claim(uint64 epochId, uint256 amount) internal pure returns (RewardHarvester.ClaimParams memory c) {
    c.epochId = epochId;
    c.amount = amount;
    c.proof = new bytes32[](0);
  }

  function _depositAlice(uint256 amount) internal {
    deal(slisBnb, alice, amount);
    vm.startPrank(alice);
    IERC20(slisBnb).approve(address(vault), amount);
    vault.deposit(amount, alice);
    vm.stopPrank();
  }

  function test_harvest_claimsToSelf_andCompounds() public {
    _depositAlice(100 ether);
    uint256 assetsBefore = vault.totalAssets();
    uint256 supplyBefore = vault.totalSupply();
    uint256 ppsBefore = vault.convertToAssets(1e18);

    RewardHarvester.ClaimParams[] memory claims = new RewardHarvester.ClaimParams[](2);
    claims[0] = _claim(1, 10 ether);
    claims[1] = _claim(2, 5 ether);

    vm.prank(bot);
    harvester.harvest(claims, 0, 0);

    uint256 staked = IStakeManagerLike(stakeManager).convertBnbToSnBnb(15 ether);

    assertEq(address(harvester).balance, 0, "all BNB injected");
    assertEq(distributor.lastClaimAccount(), address(harvester), "claim _account hardcoded to harvester");
    assertEq(vault.totalSupply(), supplyBefore, "no user shares minted");
    assertApproxEqAbs(vault.totalAssets(), assetsBefore + staked, 3, "totalAssets += staked reward");
    assertGt(vault.convertToAssets(1e18), ppsBefore, "pricePerShare up");
  }

  function test_harvest_skipsAlreadyClaimed() public {
    _depositAlice(100 ether);

    // first harvest: claim epoch 1 (10 BNB)
    RewardHarvester.ClaimParams[] memory first = new RewardHarvester.ClaimParams[](1);
    first[0] = _claim(1, 10 ether);
    vm.prank(bot);
    harvester.harvest(first, 0, 0);
    uint256 distBalAfterFirst = address(distributor).balance;

    // second harvest: epoch 1 (already claimed, skipped) + epoch 2 (5 BNB)
    RewardHarvester.ClaimParams[] memory second = new RewardHarvester.ClaimParams[](2);
    second[0] = _claim(1, 10 ether);
    second[1] = _claim(2, 5 ether);
    vm.prank(bot);
    harvester.harvest(second, 0, 0);

    // only epoch 2 paid out in the second call
    assertEq(distBalAfterFirst - address(distributor).balance, 5 ether, "epoch1 not double-claimed");
  }

  function test_harvest_revertsBelowMinBNBOut() public {
    _depositAlice(50 ether);
    RewardHarvester.ClaimParams[] memory claims = new RewardHarvester.ClaimParams[](1);
    claims[0] = _claim(1, 10 ether);

    vm.prank(bot);
    vm.expectRevert(RewardHarvester.InsufficientReward.selector);
    harvester.harvest(claims, 20 ether, 0); // minBNBOut > claimable
  }

  function test_harvest_revertsNothingToCompound() public {
    RewardHarvester.ClaimParams[] memory none = new RewardHarvester.ClaimParams[](0);
    vm.prank(bot);
    vm.expectRevert(RewardHarvester.NothingToCompound.selector);
    harvester.harvest(none, 0, 0);
  }

  function test_harvest_onlyBot() public {
    RewardHarvester.ClaimParams[] memory claims = new RewardHarvester.ClaimParams[](1);
    claims[0] = _claim(1, 10 ether);
    vm.prank(alice);
    vm.expectRevert();
    harvester.harvest(claims, 0, 0);
  }

  function test_rescue_managerOnly() public {
    address to = makeAddr("rescueTo");

    // BNB rescue
    vm.deal(address(harvester), 3 ether);
    vm.prank(alice);
    vm.expectRevert();
    harvester.rescue(address(0), to, 3 ether);

    vm.prank(hManager);
    harvester.rescue(address(0), to, 3 ether);
    assertEq(to.balance, 3 ether, "BNB rescued");

    // ERC20 rescue
    deal(slisBnb, address(harvester), 7 ether);
    vm.prank(hManager);
    harvester.rescue(slisBnb, to, 7 ether);
    assertEq(IERC20(slisBnb).balanceOf(to), 7 ether, "ERC20 rescued");
  }
}

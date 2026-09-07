// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { YieldAccount } from "../../src/utils/YieldAccount.sol";

/// @dev Single instance on purpose — no factory. A second owner or market means a second proxy
///      from this same implementation.
/// @dev Prerequisite: the market must already have the provider registered (`Moolah.setProvider`),
///      or initialize reverts ProviderNotRegistered.
contract DeployYieldAccount is DeployBase {
  using MarketParamsLib for MarketParams;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // protocol TimeLock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // B0c6
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address provider = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f; // lending SlisBNBProvider

  // holds OWNER, receives borrowed assets and withdrawn principal, and is the slisBNBx delegatee
  // (97% user share; the module's 3% feeRate goes to the minter's MPC wallets)
  address owner = 0x0966602E47F6a3CA5692529F1D54EcD1d9B09175;

  // skim destination for collateral value above principal. MANAGER-settable afterwards.
  address treasury = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // B0c6

  // skims below this BNB value are skipped; a full exit force-skims regardless
  uint256 minSkimBnb = 0.005 ether;

  // market: lisUSD / slisBNB, multiOracle, alphaIrm, LLTV 85%
  address lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address alphaIrm = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;
  uint256 lltv85 = 85 * 1e16;

  address[] receivers;

  // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
  bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory params = MarketParams({
      loanToken: lisUSD,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: alphaIrm,
      lltv: lltv85
    });
    console.log("Market id: ");
    console.logBytes32(Id.unwrap(params.id()));

    // borrowed assets and withdrawn principal can only go to a whitelisted receiver
    receivers.push(owner);

    vm.startBroadcast(deployerPrivateKey);

    // the owner is baked into the implementation: one implementation per account
    YieldAccount impl = new YieldAccount(moolah, provider, owner);
    console.log("YieldAccount implementation: ", address(impl));

    // initialize rides in the proxy constructor: no block where this proxy is uninitialized
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(YieldAccount.initialize, (admin, manager, pauser, params, treasury, minSkimBnb, owner, receivers))
    );
    console.log("YieldAccount proxy: ", address(proxy));

    vm.stopBroadcast();

    // self-check outside the broadcast: a wrong value above stops the run instead of shipping
    YieldAccount account = YieldAccount(address(proxy));
    require(address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT)))) == address(impl), "impl slot");
    require(address(account.MOOLAH()) == moolah, "moolah");
    require(address(account.PROVIDER()) == provider, "provider");
    require(account.TOKEN() == slisBNB, "token");
    require(Id.unwrap(account.marketId()) == Id.unwrap(params.id()), "market id");
    require(account.treasury() == treasury, "treasury");
    require(account.minSkimBnb() == minSkimBnb, "minSkimBnb");
    require(account.principalBnb() == 0, "principal");
    require(account.isReceiver(owner), "receiver");
    require(account.migrator() == address(0), "migrator preset");

    require(account.hasRole(account.DEFAULT_ADMIN_ROLE(), admin), "admin");
    require(account.hasRole(account.MANAGER(), manager), "manager");
    require(account.hasRole(account.PAUSER(), pauser), "pauser");
    require(account.OWNER() == owner, "owner");
    require(account.getRoleMemberCount(account.DEFAULT_ADMIN_ROLE()) == 1, "admin count");
    require(account.getRoleMemberCount(account.MANAGER()) == 1, "manager count");
    require(account.getRoleMemberCount(account.PAUSER()) == 1, "pauser count");
    require(!account.hasRole(account.DEFAULT_ADMIN_ROLE(), deployer), "deployer is admin");
    require(!account.hasRole(account.MANAGER(), deployer), "deployer is manager");
    // so a leaked pauser key can be revoked without a 24h proposal
    require(account.getRoleAdmin(account.PAUSER()) == account.MANAGER(), "pauser role admin");
  }
}

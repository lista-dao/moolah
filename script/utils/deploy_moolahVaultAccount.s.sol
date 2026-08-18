// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVaultAccount } from "../../src/utils/MoolahVaultAccount.sol";

contract DeployMoolahVaultAccount is DeployBase {
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // protocol TimeLock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // B0c6
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  address vault = 0xE03D86e5Baa3509AC4A059A41737bAa8169B6529; // lisUSD MoolahVault
  address principalOwner = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // B0c6
  uint256 principal = 28_300_000 ether;

  address lsrPool = 0x37DB1AE9B24055D1F9fE973Aea40B7EB2995D0Bf; // LisUSDPoolSet
  address usdtBuyback = 0x3b99A4177E3f430590A8473f353dD87a5a2e1BfC;

  address[] yieldRecipients;

  // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
  bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    yieldRecipients.push(lsrPool);
    yieldRecipients.push(usdtBuyback);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy MoolahVaultAccount implementation
    MoolahVaultAccount impl = new MoolahVaultAccount();
    console.log("MoolahVaultAccount implementation: ", address(impl));

    // Deploy MoolahVaultAccount proxy, initialized straight to the final role holders. The initialize
    // calldata rides in the proxy constructor, so no block exists in which this proxy is deployed but
    // uninitialized. abi.encodeCall (not encodeWithSelector) type-checks the arguments at compile time.
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(
        MoolahVaultAccount.initialize,
        (admin, manager, bot, pauser, vault, principalOwner, principal, yieldRecipients)
      )
    );
    console.log("MoolahVaultAccount proxy: ", address(proxy));

    vm.stopBroadcast();

    // Self-check outside the broadcast: view calls, no transactions, no gas. A wrong value in the table
    // above stops the run here instead of shipping.
    MoolahVaultAccount account = MoolahVaultAccount(address(proxy));
    require(address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT)))) == address(impl), "impl slot");
    require(account.hasRole(account.DEFAULT_ADMIN_ROLE(), admin), "admin");
    require(account.hasRole(account.MANAGER(), manager), "manager");
    require(account.hasRole(account.BOT(), bot), "bot");
    require(account.hasRole(account.PAUSER(), pauser), "pauser");
    require(account.getRoleMemberCount(account.DEFAULT_ADMIN_ROLE()) == 1, "admin count");
    require(account.getRoleMemberCount(account.MANAGER()) == 1, "manager count");
    require(account.getRoleMemberCount(account.BOT()) == 1, "bot count");
    require(account.getRoleMemberCount(account.PAUSER()) == 1, "pauser count");
    require(!account.hasRole(account.DEFAULT_ADMIN_ROLE(), deployer), "deployer is admin");
    require(!account.hasRole(account.MANAGER(), deployer), "deployer is manager");
    // MANAGER administers BOT and PAUSER so a leaked key can be rotated without a 24h proposal
    require(account.getRoleAdmin(account.BOT()) == account.MANAGER(), "bot role admin");
    require(account.getRoleAdmin(account.PAUSER()) == account.MANAGER(), "pauser role admin");
    require(address(account.vault()) == vault, "vault");
    require(account.principalOwner() == principalOwner, "principalOwner");
    require(account.principal() == principal, "principal");
    require(account.getYieldRecipients().length == 2, "recipients");
  }
}

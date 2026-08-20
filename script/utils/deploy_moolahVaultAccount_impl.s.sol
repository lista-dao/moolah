// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { MoolahVaultAccount } from "../../src/utils/MoolahVaultAccount.sol";

/// @dev deploys a new implementation only. The TimeLock then calls
///      proxy.upgradeToAndCall(newImpl, "") — this script must never touch the proxy.
contract DeployMoolahVaultAccountImpl is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer: ", vm.addr(deployerPrivateKey));

    vm.startBroadcast(deployerPrivateKey);

    MoolahVaultAccount impl = new MoolahVaultAccount();
    console.log("MoolahVaultAccount implementation: ", address(impl));

    vm.stopBroadcast();

    // The constructor must have burned the initializer. Outside the broadcast this is a local call, not
    // a transaction: an implementation that can still be initialized never ships.
    address deployer = vm.addr(deployerPrivateKey);
    address[] memory recipients = new address[](1);
    recipients[0] = deployer;
    (bool initializable, bytes memory ret) = address(impl).call(
      abi.encodeCall(
        MoolahVaultAccount.initialize,
        (deployer, deployer, deployer, deployer, deployer, deployer, 1, recipients)
      )
    );
    require(!initializable, "implementation must not be initializable");
    // It has to fail for the RIGHT reason. `_vault` is `deployer`, an EOA, so an implementation with
    // no _disableInitializers() would still revert here — at IMoolahVault(_vault).asset() — and the
    // check above would pass on a broken implementation. Only InvalidInitialization proves the
    // initializer was burned before any argument was touched.
    require(ret.length >= 4, "implementation reverted without a reason");
    require(bytes4(ret) == Initializable.InvalidInitialization.selector, "initializer was not burned");
  }
}

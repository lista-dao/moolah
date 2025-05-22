// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IMoolahVaultFactory } from "moolah-vault/interfaces/IMoolahVaultFactory.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MoolahVaultFactory } from "moolah-vault/MoolahVaultFactory.sol";
import { ERC20Mock } from "moolah-vault/mocks/ERC20Mock.sol";
import { TimeLock } from "timelock/TimeLock.sol";


contract MoolahVaultFactoryTest is Test {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address admin;
  address curator;
  address guardian;
  address vaultAdmin;
  uint256 timeLockDelay = 1 days;
  address asset = 0x55d398326f99059fF775485246999027B3197955;

  IMoolahVaultFactory factory;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    admin = makeAddr("admin");
    curator = makeAddr("curator");
    guardian = makeAddr("guardian");
    vaultAdmin = makeAddr("vaultAdmin");

    factory = newMoolahVaultFactory();
  }

  function test_createMoolahVault() public {
    (address vaultAddr, address managerTimeLockAddr, address curatorTimeLockAddr) = factory.createMoolahVault(
      admin,
      curator,
      guardian,
      timeLockDelay,
      asset,
      "test name",
      "test symbol"
    );

    MoolahVault vault = MoolahVault(vaultAddr);
    TimeLock managerTimeLock = TimeLock(payable(managerTimeLockAddr));
    TimeLock curatorTimeLock = TimeLock(payable(curatorTimeLockAddr));

    assertEq(vault.asset(), asset, "asset error");

    assertEq(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()), 1, "admin role error");
    assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), vaultAdmin), true, "admin role error");
    assertEq(vault.getRoleMemberCount(vault.MANAGER()), 1, "manager role error");
    assertEq(vault.hasRole(vault.MANAGER(), managerTimeLockAddr), true, "admin role error");
    assertEq(vault.getRoleMemberCount(vault.CURATOR()), 1, "curator role error");
    assertEq(vault.hasRole(vault.CURATOR(), curatorTimeLockAddr), true, "curator role error");


    assertEq(managerTimeLock.getRoleMemberCount(managerTimeLock.DEFAULT_ADMIN_ROLE()), 1, "admin role error");
    assertEq(managerTimeLock.hasRole(managerTimeLock.DEFAULT_ADMIN_ROLE(), address(managerTimeLock)), true, "admin role error");
    assertEq(managerTimeLock.getRoleMemberCount(managerTimeLock.PROPOSER_ROLE()), 1, "proposer role error");
    assertEq(managerTimeLock.hasRole(managerTimeLock.PROPOSER_ROLE(), admin), true, "proposer role error");
    assertEq(managerTimeLock.getRoleMemberCount(managerTimeLock.EXECUTOR_ROLE()), 1, "executor role error");
    assertEq(managerTimeLock.hasRole(managerTimeLock.EXECUTOR_ROLE(), admin), true, "executor role error");
    assertEq(managerTimeLock.getRoleMemberCount(managerTimeLock.CANCELLER_ROLE()), 2, "canceller role error");
    assertEq(managerTimeLock.hasRole(managerTimeLock.CANCELLER_ROLE(), admin), true, "canceller role error");
    assertEq(managerTimeLock.hasRole(managerTimeLock.CANCELLER_ROLE(), guardian), true, "canceller role error");

    assertEq(curatorTimeLock.getRoleMemberCount(curatorTimeLock.DEFAULT_ADMIN_ROLE()), 1, "admin role error");
    assertEq(curatorTimeLock.hasRole(curatorTimeLock.DEFAULT_ADMIN_ROLE(), address(curatorTimeLock)), true, "admin role error");
    assertEq(curatorTimeLock.getRoleMemberCount(curatorTimeLock.PROPOSER_ROLE()), 1, "proposer role error");
    assertEq(curatorTimeLock.hasRole(curatorTimeLock.PROPOSER_ROLE(), curator), true, "proposer role error");
    assertEq(curatorTimeLock.getRoleMemberCount(curatorTimeLock.EXECUTOR_ROLE()), 1, "executor role error");
    assertEq(curatorTimeLock.hasRole(curatorTimeLock.EXECUTOR_ROLE(), curator), true, "executor role error");
    assertEq(curatorTimeLock.getRoleMemberCount(curatorTimeLock.CANCELLER_ROLE()), 2, "canceller role error");
    assertEq(curatorTimeLock.hasRole(curatorTimeLock.CANCELLER_ROLE(), curator), true, "canceller role error");
    assertEq(curatorTimeLock.hasRole(curatorTimeLock.CANCELLER_ROLE(), guardian), true, "canceller role error");


  }

  function newMoolahVaultFactory() internal returns (IMoolahVaultFactory) {
    MoolahVaultFactory impl = new MoolahVaultFactory(moolah);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        admin,
        vaultAdmin
      )
    );

    return IMoolahVaultFactory(address(proxy));
  }
}

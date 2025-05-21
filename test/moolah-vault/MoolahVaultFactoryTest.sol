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
  address moolah;
  address admin;
  address vaultAdmin;
  ERC20Mock internal asset = new ERC20Mock("loan", "B");

  IMoolahVaultFactory factory;

  function setUp() public {
    moolah = makeAddr("mooah");
    admin = makeAddr("admin");
    vaultAdmin = makeAddr("vaultAdmin");

    factory = newMoolahVaultFactory();
  }

  function test_createMoolahVault() public {
    (address vaultAddr, address timeLockAddr) = factory.createMoolahVault(admin, address(asset), "test name", "test symbol", 0x0);

    MoolahVault vault = MoolahVault(vaultAddr);
    TimeLock timeLock = TimeLock(payable(timeLockAddr));

    assertEq(vault.asset(), address(asset), "asset error");

    assertEq(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()), 1, "admin role error");
    assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), vaultAdmin), true, "admin role error");
    assertEq(vault.getRoleMemberCount(vault.MANAGER()), 1, "manager role error");
    assertEq(vault.hasRole(vault.MANAGER(), admin), true, "admin role error");

    assertEq(timeLock.getRoleMemberCount(timeLock.DEFAULT_ADMIN_ROLE()), 1, "admin role error");
    assertEq(timeLock.hasRole(timeLock.DEFAULT_ADMIN_ROLE(), address(timeLock)), true, "admin role error");
    assertEq(timeLock.getRoleMemberCount(timeLock.PROPOSER_ROLE()), 1, "proposer role error");
    assertEq(timeLock.hasRole(timeLock.PROPOSER_ROLE(), admin), true, "proposer role error");
    assertEq(timeLock.getRoleMemberCount(timeLock.EXECUTOR_ROLE()), 1, "executor role error");
    assertEq(timeLock.hasRole(timeLock.EXECUTOR_ROLE(), admin), true, "executor role error");
    assertEq(timeLock.getRoleMemberCount(timeLock.CANCELLER_ROLE()), 1, "canceller role error");
    assertEq(timeLock.hasRole(timeLock.CANCELLER_ROLE(), admin), true, "canceller role error");

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

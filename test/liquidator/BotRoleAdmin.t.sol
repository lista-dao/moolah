// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { BrokerLiquidator } from "liquidator/BrokerLiquidator.sol";

/// @dev Verifies BOT's role admin is MANAGER (not DEFAULT_ADMIN) across the vault and both liquidators,
///      so BOT hot-key rotation is a MANAGER (multisig) action.
contract BotRoleAdminTest is Test {
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address newBot = makeAddr("newBot");
  address moolah = makeAddr("moolah");

  bytes32 constant MANAGER = keccak256("MANAGER");
  bytes32 constant BOT = keccak256("BOT");
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

  function _proxy(address impl, bytes memory data) internal returns (address) {
    return address(new ERC1967Proxy(impl, data));
  }

  function test_vault_botAdminIsManager() public {
    LiquidationVault v = LiquidationVault(
      payable(
        _proxy(
          address(new LiquidationVault()),
          abi.encodeWithSelector(LiquidationVault.initialize.selector, admin, manager, pauser, bot)
        )
      )
    );
    assertEq(v.getRoleAdmin(BOT), MANAGER);

    // MANAGER can rotate BOT without DEFAULT_ADMIN.
    vm.prank(manager);
    v.grantRole(BOT, newBot);
    assertTrue(v.hasRole(BOT, newBot));
  }

  function test_liquidator_botAdminIsManager() public {
    Liquidator l = Liquidator(
      payable(
        _proxy(
          address(new Liquidator(moolah)),
          abi.encodeWithSelector(Liquidator.initialize.selector, admin, manager, bot)
        )
      )
    );
    assertEq(l.getRoleAdmin(BOT), MANAGER);
    vm.prank(manager);
    l.grantRole(BOT, newBot);
    assertTrue(l.hasRole(BOT, newBot));

    // setBotRoleAdmin is DEFAULT_ADMIN-gated and idempotently re-callable.
    vm.prank(bot);
    vm.expectRevert();
    l.setBotRoleAdmin();

    vm.prank(admin);
    l.setBotRoleAdmin();
    assertEq(l.getRoleAdmin(BOT), MANAGER);

    // re-callable (no one-shot reinitializer guard)
    vm.prank(admin);
    l.setBotRoleAdmin();
    assertEq(l.getRoleAdmin(BOT), MANAGER);
  }

  function test_brokerLiquidator_botAdminIsManager() public {
    BrokerLiquidator b = BrokerLiquidator(
      payable(
        _proxy(
          address(new BrokerLiquidator(moolah)),
          abi.encodeWithSelector(BrokerLiquidator.initialize.selector, admin, manager, bot)
        )
      )
    );
    assertEq(b.getRoleAdmin(BOT), MANAGER);
    vm.prank(manager);
    b.grantRole(BOT, newBot);
    assertTrue(b.hasRole(BOT, newBot));

    vm.prank(admin);
    b.setBotRoleAdmin();
    assertEq(b.getRoleAdmin(BOT), MANAGER);
  }
}

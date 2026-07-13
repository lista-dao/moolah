// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { RevenueCollector } from "../../src/revenue/RevenueCollector.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

/// @dev Validates the RevenueCollector -> LiquidationVault fee-pull path with zero collector code
///      changes: the vault mimics the ILiquidator withdraw interface, so the collector's existing
///      claimLiquidationFee resolves against it once the vault is registered and set as revenueCollector.
contract LiquidationVaultRevenueCollectorTest is Test {
  LiquidationVault vault;
  RevenueCollector collector;
  ERC20Mock token;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  event LiquidationFeeCollected(address indexed liquidator, address indexed asset, uint256 amount);

  function setUp() public {
    token = new ERC20Mock();

    // Vault
    LiquidationVault vImpl = new LiquidationVault();
    vault = LiquidationVault(
      payable(
        address(
          new ERC1967Proxy(
            address(vImpl),
            abi.encodeWithSelector(vImpl.initialize.selector, admin, manager, pauser, bot)
          )
        )
      )
    );

    // RevenueCollector
    address[] memory pools = new address[](0);
    address[] memory liquidators = new address[](0);
    RevenueCollector rcImpl = new RevenueCollector();
    collector = RevenueCollector(
      payable(
        address(
          new ERC1967Proxy(
            address(rcImpl),
            abi.encodeWithSelector(rcImpl.initialize.selector, admin, manager, bot, pools, liquidators)
          )
        )
      )
    );

    // Wire-up: authorize collector on the vault, and register the vault on the collector.
    vm.prank(manager);
    vault.setRevenueCollector(address(collector));
    vm.prank(manager);
    collector.updateLiquidator(address(vault), true);
    vm.prank(manager);
    vault.setTokenWhitelist(BNB_ADDRESS, true);
  }

  function test_collector_pullsERC20Fee() public {
    token.setBalance(address(vault), 100e18);

    vm.expectEmit(true, true, false, true, address(collector));
    emit LiquidationFeeCollected(address(vault), address(token), 40e18);

    vm.prank(bot);
    collector.claimLiquidationFee(address(vault), address(token), 40e18);

    assertEq(token.balanceOf(address(collector)), 40e18);
    assertEq(token.balanceOf(address(vault)), 60e18);
  }

  function test_collector_pullsNativeFee() public {
    vm.deal(address(vault), 5 ether);

    vm.prank(bot);
    collector.claimLiquidationFee(address(vault), BNB_ADDRESS, 5 ether);

    assertEq(address(collector).balance, 5 ether);
  }

  function test_collector_previewReflectsVaultBalance() public {
    token.setBalance(address(vault), 10e18);
    assertTrue(collector.previewClaimLiquidationFee(address(vault), address(token), 10e18));
    assertFalse(collector.previewClaimLiquidationFee(address(vault), address(token), 11e18));
  }

  function test_vault_withdrawRejectsNonCollectorNonManager() public {
    token.setBalance(address(vault), 10e18);
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(LiquidationVault.NotAuthorized.selector);
    vault.withdrawERC20(address(token), 1e18);
  }
}

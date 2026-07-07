// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";
import { ILiquidatorWithdraw } from "liquidator/ILiquidationVault.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

/// @dev Minimal ResilientOracle stand-in: settable 8-decimal USD prices.
contract MockOracle {
  mapping(address => uint256) public price; // 8-decimal USD

  function setPrice(address token, uint256 p) external {
    price[token] = p;
  }

  function peek(address token) external view returns (uint256) {
    return price[token];
  }
}

/// @dev Stand-in liquidator holding balances; withdraw* transfers to msg.sender (the vault), matching
///      the real liquidators' ILiquidator semantics used by collect*.
contract MockWithdrawLiquidator {
  function withdrawERC20(address token, uint256 amount) external {
    ERC20Mock(token).transfer(msg.sender, amount);
  }

  function withdrawETH(uint256 amount) external {
    (bool ok, ) = msg.sender.call{ value: amount }("");
    require(ok, "eth send failed");
  }

  receive() external payable {}
}

/// @dev Stand-in swap venue. `swap` pulls tokenIn via the allowance and returns a fixed tokenOut.
contract MockRouter {
  function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
    ERC20Mock(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    ERC20Mock(tokenOut).transfer(msg.sender, amountOut);
  }

  function swapBNB(address tokenOut, uint256 amountOut) external payable {
    ERC20Mock(tokenOut).transfer(msg.sender, amountOut);
  }

  receive() external payable {}
}

contract LiquidationVaultTest is Test {
  LiquidationVault vault;
  MockOracle oracle;
  MockWithdrawLiquidator liq;
  MockRouter router;
  ERC20Mock tokenA;
  ERC20Mock tokenB;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address rc = makeAddr("revenueCollector");
  address stranger = makeAddr("stranger");

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  uint256 constant PRICE_1USD = 1e8; // 8-decimal USD

  function setUp() public {
    oracle = new MockOracle();
    liq = new MockWithdrawLiquidator();
    router = new MockRouter();
    tokenA = new ERC20Mock();
    tokenB = new ERC20Mock();

    LiquidationVault impl = new LiquidationVault();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager, pauser, bot)
    );
    vault = LiquidationVault(payable(address(proxy)));

    vm.startPrank(manager);
    vault.setOracle(address(oracle));
    vault.setTokenWhitelist(address(tokenA), true);
    vault.setTokenWhitelist(address(tokenB), true);
    vault.setTokenWhitelist(BNB_ADDRESS, true);
    vault.setPairWhitelist(address(router), true);
    vault.setLiquidator(address(liq), true);
    vm.stopPrank();

    oracle.setPrice(address(tokenA), PRICE_1USD);
    oracle.setPrice(address(tokenB), PRICE_1USD);
    oracle.setPrice(BNB_ADDRESS, PRICE_1USD);
  }

  // ----------------------------- provideFund ----------------------------- //

  function test_provideFund_registeredPullsToSelf() public {
    tokenA.setBalance(address(vault), 100e18);
    vm.prank(address(liq));
    vault.provideFund(address(tokenA), 40e18);
    assertEq(tokenA.balanceOf(address(liq)), 40e18);
    assertEq(tokenA.balanceOf(address(vault)), 60e18);
  }

  function test_provideFund_unregisteredReverts() public {
    tokenA.setBalance(address(vault), 100e18);
    vm.prank(stranger);
    vm.expectRevert(LiquidationVault.NotRegistered.selector);
    vault.provideFund(address(tokenA), 1e18);
  }

  function test_provideFund_pausedReverts() public {
    tokenA.setBalance(address(vault), 100e18);
    vm.prank(pauser);
    vault.pause();
    vm.prank(address(liq));
    vm.expectRevert(); // Pausable: paused
    vault.provideFund(address(tokenA), 1e18);
  }

  // ----------------------------- collect* ----------------------------- //

  function test_collectERC20_botWhitelistedToken() public {
    tokenA.setBalance(address(liq), 30e18);
    vm.prank(bot);
    vault.collectERC20(address(liq), address(tokenA), 30e18);
    assertEq(tokenA.balanceOf(address(vault)), 30e18);
  }

  function test_collectERC20_botNonWhitelistedReverts() public {
    ERC20Mock tokenC = new ERC20Mock();
    tokenC.setBalance(address(liq), 10e18);
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.NotWhitelisted.selector);
    vault.collectERC20(address(liq), address(tokenC), 10e18);
  }

  function test_collectERC20_managerRescuesNonWhitelisted() public {
    ERC20Mock tokenC = new ERC20Mock();
    tokenC.setBalance(address(liq), 10e18);
    vm.prank(manager);
    vault.collectERC20(address(liq), address(tokenC), 10e18);
    assertEq(tokenC.balanceOf(address(vault)), 10e18);
  }

  function test_collectERC20_unregisteredLiquidatorReverts() public {
    MockWithdrawLiquidator other = new MockWithdrawLiquidator();
    tokenA.setBalance(address(other), 5e18);
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.NotRegistered.selector);
    vault.collectERC20(address(other), address(tokenA), 5e18);
  }

  function test_collectETH_botPullsNative() public {
    vm.deal(address(liq), 5 ether);
    vm.prank(bot);
    vault.collectETH(address(liq), 5 ether);
    assertEq(address(vault).balance, 5 ether);
  }

  // ----------------------------- sell + loss guard ----------------------------- //

  function _fairSwapData(uint256 amountIn, uint256 amountOut) internal view returns (bytes memory) {
    return abi.encodeWithSelector(MockRouter.swap.selector, address(tokenA), address(tokenB), amountIn, amountOut);
  }

  function test_sellToken_fairSwapPasses() public {
    tokenA.setBalance(address(vault), 100e18);
    tokenB.setBalance(address(router), 100e18);
    vm.prank(bot);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      100e18,
      _fairSwapData(100e18, 100e18)
    );
    assertEq(tokenB.balanceOf(address(vault)), 100e18);
  }

  function test_sellToken_notWhitelistedTokenReverts() public {
    ERC20Mock tokenC = new ERC20Mock();
    tokenC.setBalance(address(vault), 100e18);
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.NotWhitelisted.selector);
    vault.sellToken(address(router), address(router), address(tokenC), address(tokenB), 1e18, 0, "");
  }

  function test_sellToken_perSwapLossCapReverts() public {
    // 10% loss > 5% cap.
    tokenA.setBalance(address(vault), 100e18);
    tokenB.setBalance(address(router), 100e18);
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.OracleLoss.selector);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      0,
      _fairSwapData(100e18, 90e18)
    );
  }

  function test_sellToken_zeroPriceFailsClosed() public {
    oracle.setPrice(address(tokenB), 0);
    tokenA.setBalance(address(vault), 100e18);
    tokenB.setBalance(address(router), 100e18);
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.OracleZero.selector);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      0,
      _fairSwapData(100e18, 100e18)
    );
  }

  function test_sellToken_dailyLossCapAndReset() public {
    // Tighten the daily cap so two 3% losses breach it.
    vm.prank(manager);
    vault.setMaxDailyLossUsd(5e8);

    tokenA.setBalance(address(vault), 1000e18);
    tokenB.setBalance(address(router), 1000e18);

    // First 3% loss (3e8) accrues under the 5e8 cap.
    vm.prank(bot);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      0,
      _fairSwapData(100e18, 97e18)
    );
    assertEq(vault.dailyLossAccum(), 3e8);

    // Second 3% loss would push to 6e8 > 5e8 -> revert.
    vm.prank(bot);
    vm.expectRevert(LiquidationVault.DailyLossExceeded.selector);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      0,
      _fairSwapData(100e18, 97e18)
    );

    // Next UTC day resets the accumulator.
    vm.warp(block.timestamp + 1 days);
    vm.prank(bot);
    vault.sellToken(
      address(router),
      address(router),
      address(tokenA),
      address(tokenB),
      100e18,
      0,
      _fairSwapData(100e18, 97e18)
    );
    assertEq(vault.dailyLossAccum(), 3e8);
  }

  // ----------------------------- withdraw gate ----------------------------- //

  function test_withdraw_managerOk_strangerReverts() public {
    tokenA.setBalance(address(vault), 10e18);
    vm.prank(manager);
    vault.withdrawERC20(address(tokenA), 4e18);
    assertEq(tokenA.balanceOf(manager), 4e18);

    vm.prank(stranger);
    vm.expectRevert(LiquidationVault.NotAuthorized.selector);
    vault.withdrawERC20(address(tokenA), 1e18);
  }

  function test_withdraw_revenueCollectorOkAfterSet() public {
    // rc is an EOA here; contract-code check applies, so use a code-bearing address.
    vm.prank(manager);
    vault.setRevenueCollector(address(router)); // any contract works as the RC stand-in
    tokenA.setBalance(address(vault), 10e18);
    vm.prank(address(router));
    vault.withdrawERC20(address(tokenA), 6e18);
    assertEq(tokenA.balanceOf(address(router)), 6e18);
  }

  // ----------------------------- pause ----------------------------- //

  function test_pause_onlyPauser_unpauseOnlyManager() public {
    vm.prank(stranger);
    vm.expectRevert();
    vault.pause();

    vm.prank(pauser);
    vault.pause();
    assertTrue(vault.paused());

    vm.prank(stranger);
    vm.expectRevert();
    vault.unpause();

    vm.prank(manager);
    vault.unpause();
    assertFalse(vault.paused());
  }

  function test_setLiquidator_onlyManager() public {
    vm.prank(stranger);
    vm.expectRevert();
    vault.setLiquidator(address(0xBEEF), true);

    vm.prank(manager);
    vault.setLiquidator(address(0xBEEF), true);
    assertTrue(vault.liquidators(address(0xBEEF)));
  }
}

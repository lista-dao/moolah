// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMoolahVault } from "moolah-vault/interfaces/IMoolahVault.sol";
import { ErrorsLib } from "moolah-vault/libraries/ErrorsLib.sol";
import { MoolahVaultAccount } from "../../src/utils/MoolahVaultAccount.sol";

contract MoolahVaultAccountForkTest is Test {
  uint256 constant FORK_BLOCK = 116_433_631;

  IMoolahVault constant VAULT = IMoolahVault(0xE03D86e5Baa3509AC4A059A41737bAa8169B6529);
  IERC20 constant LISUSD = IERC20(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);
  address constant B0C6 = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LENDING_TIMELOCK = 0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85;
  address constant PROTOCOL_TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant LSR_POOL = 0x37DB1AE9B24055D1F9fE973Aea40B7EB2995D0Bf;
  address constant USDT_BUYBACK = 0x3b99A4177E3f430590A8473f353dD87a5a2e1BfC;
  address constant BOT_EOA = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address constant PAUSER_EOA = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  uint256 constant PRINCIPAL = 28_300_000 ether;

  MoolahVaultAccount manager;

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    address[] memory recipients = new address[](2);
    recipients[0] = LSR_POOL;
    recipients[1] = USDT_BUYBACK;

    MoolahVaultAccount impl = new MoolahVaultAccount();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(
        MoolahVaultAccount.initialize,
        (PROTOCOL_TIMELOCK, B0C6, BOT_EOA, PAUSER_EOA, address(VAULT), B0C6, PRINCIPAL, recipients)
      )
    );
    manager = MoolahVaultAccount(address(proxy));

    // launch step 3: B0c6 transfers the whole position in, with no contract-side hook
    uint256 shares = VAULT.balanceOf(B0C6);
    vm.prank(B0C6);
    VAULT.transfer(address(manager), shares);
    assertEq(VAULT.balanceOf(address(manager)), shares);
    assertEq(VAULT.balanceOf(B0C6), 0);
  }

  /// @dev the position transfer needs no whitelist: the vault gates only deposit/mint receivers.
  function test_fork_positionTransferNeedsNoWhitelist() public view {
    assertFalse(VAULT.isWhiteList(address(manager)));
    assertGt(VAULT.balanceOf(address(manager)), 0);
  }

  function test_fork_backlogMatchesExpectation() public view {
    uint256 assets = manager.totalAssets();
    assertApproxEqAbs(assets, 28_492_314.211909e18, 1e18);

    uint256 claimable = manager.claimableYield();
    assertEq(claimable, assets - PRINCIPAL);
    assertApproxEqAbs(claimable, 192_314.21e18, 1e18);

    // C3 with the live fee (1e17): the naive share of totalAssets ignores accrued-but-unminted fee
    // shares and reads ~29.6 lisUSD high. totalAssets() must be the lower, fee-adjusted figure.
    uint256 shares = VAULT.balanceOf(address(manager));
    uint256 naive = (VAULT.totalAssets() * shares) / VAULT.totalSupply();
    assertLt(assets, naive);
    assertApproxEqAbs(naive - assets, 29.6e18, 1e18);
  }

  function test_fork_previewClaimReportsRealLiquidity() public view {
    (uint256 claimable, uint256 withdrawable, uint256 claimableNow) = manager.previewClaim();
    assertGt(withdrawable, 0);
    // ~9.96M of queue liquidity against a ~192k backlog, so nothing is clamped at this block
    assertGt(withdrawable, claimable);
    assertEq(claimableNow, claimable);
  }

  /// @dev the headline flow: split the real backlog between the live LSR pool and the live Buyback.
  function test_fork_claimYieldSplitsBacklogAcrossBothDestinations() public {
    uint256 claimable = manager.claimableYield();
    uint256 toLsr = 50_000e18;
    uint256 toBuyback = claimable - toLsr;

    uint256 lsrBefore = LISUSD.balanceOf(LSR_POOL);
    uint256 buybackBefore = LISUSD.balanceOf(USDT_BUYBACK);

    MoolahVaultAccount.Payment[] memory p = new MoolahVaultAccount.Payment[](2);
    p[0] = MoolahVaultAccount.Payment({ to: LSR_POOL, amount: toLsr });
    p[1] = MoolahVaultAccount.Payment({ to: USDT_BUYBACK, amount: toBuyback });

    vm.prank(BOT_EOA);
    uint256 total = manager.claimYield(p);

    assertEq(total, claimable);
    assertEq(LISUSD.balanceOf(LSR_POOL) - lsrBefore, toLsr);
    assertEq(LISUSD.balanceOf(USDT_BUYBACK) - buybackBefore, toBuyback);
    assertEq(LISUSD.balanceOf(address(manager)), 0);

    // principal is intact up to the share-price dust bound
    uint256 assets = manager.totalAssets();
    assertLe(assets, PRINCIPAL);
    assertGe(assets + VAULT.convertToAssets(1) + 1, PRINCIPAL);
    assertEq(manager.claimableYield(), 0);
  }

  function test_fork_claimYieldRevertsAboveClaimable() public {
    uint256 claimable = manager.claimableYield();

    MoolahVaultAccount.Payment[] memory p = new MoolahVaultAccount.Payment[](1);
    p[0] = MoolahVaultAccount.Payment({ to: USDT_BUYBACK, amount: claimable + 1 ether });

    vm.prank(BOT_EOA);
    vm.expectRevert(MoolahVaultAccount.ExceedsClaimable.selector);
    manager.claimYield(p);
  }

  /// @dev C2 with the real selector: a withdrawal beyond queue liquidity reverts, never partially fills.
  function test_fork_withdrawPrincipalRevertsBeyondLiquidity() public {
    uint256 withdrawable = VAULT.maxWithdraw(address(manager));
    assertLt(withdrawable, PRINCIPAL); // the position is mostly lent out, so this is a real ceiling

    vm.prank(B0C6);
    vm.expectRevert(ErrorsLib.NotEnoughLiquidity.selector);
    manager.withdrawPrincipal(withdrawable + 1_000 ether);

    // and just at the ceiling succeeds
    uint256 before = LISUSD.balanceOf(B0C6);
    vm.prank(B0C6);
    manager.withdrawPrincipal(withdrawable);
    assertEq(LISUSD.balanceOf(B0C6) - before, withdrawable);
    assertEq(manager.principal(), PRINCIPAL - withdrawable);
  }

  /// @dev the emergency exit hands over shares, so it does not touch the withdraw queue: it moves the
  ///      whole ~28.27M position at this block even though maxRedeem is far below it — the same state
  ///      in which withdrawPrincipal and claimYield revert NotEnoughLiquidity().
  function test_fork_emergencyWithdrawMovesSharesAtAnyLiquidity() public {
    uint256 held = VAULT.balanceOf(address(manager));
    assertLt(VAULT.maxRedeem(address(manager)), held); // the position is mostly lent out

    vm.prank(B0C6);
    uint256 shares = manager.emergencyWithdraw();

    assertEq(shares, held);
    assertEq(VAULT.balanceOf(B0C6), held);
    assertEq(VAULT.balanceOf(address(manager)), 0);
    assertEq(manager.principal(), 0);
    assertEq(manager.claimableYield(), 0);
    assertEq(LISUSD.balanceOf(address(manager)), 0);
  }

  /// @dev depositPrincipal is the one path that needs the vault whitelist, and only the Lending
  ///      TimeLock can grant it.
  function test_fork_depositPrincipalNeedsWhitelist() public {
    uint256 amount = 1_000 ether;
    deal(address(LISUSD), B0C6, amount);
    vm.prank(B0C6);
    LISUSD.approve(address(manager), amount);

    vm.prank(B0C6);
    vm.expectRevert(ErrorsLib.NotWhiteList.selector);
    manager.depositPrincipal(amount);

    vm.prank(LENDING_TIMELOCK);
    VAULT.setWhiteList(address(manager), true);

    vm.prank(B0C6);
    manager.depositPrincipal(amount);
    assertEq(manager.principal(), PRINCIPAL + amount);
  }
}

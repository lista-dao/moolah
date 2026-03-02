// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IStableSwap } from "../../src/dex/interfaces/IStableSwap.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { RevenueCollector } from "../../src/revenue/RevenueCollector.sol";
import { Liquidator } from "../../src/liquidator/Liquidator.sol";
import { BrokerLiquidator } from "../../src/liquidator/BrokerLiquidator.sol";

contract RevenueCollectorTest is Test {
  RevenueCollector revenueCollector;

  MockStableSwap mockPool1;
  MockStableSwap mockPool2;

  Liquidator liquidator1;
  BrokerLiquidator liquidator2;

  ERC20Mock token0 = new ERC20Mock();
  ERC20Mock token1 = new ERC20Mock();
  address token3 = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  ERC20Mock token4 = new ERC20Mock();
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  address admin = address(0x1);
  address manager = address(0x2);
  address bot = address(0x3);
  address factory = address(0x4);
  address moolah = address(0x5);

  function setUp() public {
    mockPool1 = new MockStableSwap(address(token0), address(token1));
    mockPool2 = new MockStableSwap(token3, address(token4));
    address[] memory pools = new address[](2);
    pools[0] = address(mockPool1);
    pools[1] = address(mockPool2);

    // deal BNB to mock pools
    vm.deal(address(mockPool1), 100 ether);
    vm.deal(address(mockPool2), 100 ether);

    Liquidator liquidator1Impl = new Liquidator(moolah);
    ERC1967Proxy proxy1 = new ERC1967Proxy(
      address(liquidator1Impl),
      abi.encodeWithSelector(Liquidator.initialize.selector, admin, manager, bot)
    );
    liquidator1 = Liquidator(payable(address(proxy1)));
    BrokerLiquidator liquidator2Impl = new BrokerLiquidator(moolah);
    ERC1967Proxy proxy2 = new ERC1967Proxy(
      address(liquidator2Impl),
      abi.encodeWithSelector(BrokerLiquidator.initialize.selector, admin, manager, bot)
    );
    liquidator2 = BrokerLiquidator(payable(address(proxy2)));
    address[] memory liquidatorAddrs = new address[](2);
    liquidatorAddrs[0] = address(liquidator1);
    liquidatorAddrs[1] = address(liquidator2);

    // fund liquidator1
    token0.setBalance(address(liquidator1), 100 ether);
    token1.setBalance(address(liquidator1), 100 ether);
    vm.deal(address(liquidator1), 100 ether);

    // fund liquidator2
    token1.setBalance(address(liquidator2), 100 ether);
    token4.setBalance(address(liquidator2), 100 ether);

    RevenueCollector impl = new RevenueCollector();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(RevenueCollector.initialize.selector, admin, manager, bot, pools, liquidatorAddrs)
    );
    revenueCollector = RevenueCollector(payable(address(proxy_)));

    assertEq(revenueCollector.hasRole(0x00, admin), true);
    assertEq(revenueCollector.hasRole(revenueCollector.MANAGER(), manager), true);
    assertEq(revenueCollector.hasRole(revenueCollector.BOT(), bot), true);
    assertEq(revenueCollector.isStableSwapPool(address(mockPool1)), true);
    assertEq(revenueCollector.isStableSwapPool(address(mockPool2)), true);
    assertEq(revenueCollector.isLiquidator(address(liquidator1)), true);
    assertEq(revenueCollector.isLiquidator(address(liquidator2)), true);
  }

  function test_batchClaimDexFees() public {
    address[] memory pools = new address[](2);
    pools[0] = address(mockPool1);
    pools[1] = address(mockPool2);

    vm.expectRevert(); // revert error: AccessControlUnauthorizedAccount
    revenueCollector.batchClaimDexFees(pools);

    vm.prank(bot);
    revenueCollector.batchClaimDexFees(pools);

    // check balances
    assertEq(token0.balanceOf(address(revenueCollector)), 100 ether);
    assertEq(token1.balanceOf(address(revenueCollector)), 100 ether);
    assertEq(token4.balanceOf(address(revenueCollector)), 100 ether);
    assertEq(address(revenueCollector).balance, 100 ether);
  }

  function test_claimDexFee() public {
    vm.prank(bot);
    revenueCollector.claimDexFee(address(mockPool1));

    // check balances
    assertEq(token0.balanceOf(address(revenueCollector)), 100 ether);
    assertEq(token1.balanceOf(address(revenueCollector)), 100 ether);

    // should revert if pool is not whitelisted
    MockStableSwap mockPool3 = new MockStableSwap(address(token0), address(token1));
    vm.prank(bot);
    vm.expectRevert("not whitelisted pool");
    revenueCollector.claimDexFee(address(mockPool3));
  }

  function test_claimLiquidationFee() public {
    // liquidator1 should be whitelisted
    assertEq(revenueCollector.isLiquidator(address(liquidator1)), true);

    vm.expectRevert(); // revert error: AccessControlUnauthorizedAccount
    revenueCollector.claimLiquidationFee(address(liquidator1), address(token0), 40 ether);

    bool success = revenueCollector.previewClaimLiquidationFee(address(liquidator1), address(token0), 40 ether);
    assertEq(success, true);

    address[] memory liquidators = revenueCollector.getLiquidators();
    assertEq(liquidators.length, 2);
    assertEq(liquidators[0], address(liquidator1));
    assertEq(liquidators[1], address(liquidator2));

    vm.prank(bot);
    vm.expectRevert("not whitelisted liquidator");
    revenueCollector.claimLiquidationFee(address(bot), address(token0), 40 ether);

    // grant manager role
    vm.startPrank(admin);
    liquidator1.grantRole(liquidator1.MANAGER(), address(revenueCollector));
    vm.stopPrank();

    vm.prank(bot);
    revenueCollector.claimLiquidationFee(address(liquidator1), address(token0), 40 ether);

    // check balance
    assertEq(token0.balanceOf(address(revenueCollector)), 40 ether);
  }

  function test_claimLiquidationFees() public {
    address[] memory assets = new address[](2);
    assets[0] = address(token1);
    assets[1] = address(token4);
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 30 ether;
    amounts[1] = 20 ether;

    // grant manager role
    vm.startPrank(admin);
    liquidator2.grantRole(liquidator2.MANAGER(), address(revenueCollector));
    vm.stopPrank();

    vm.prank(bot);
    revenueCollector.claimLiquidationFees(address(liquidator2), assets, amounts);

    // check balances
    assertEq(token1.balanceOf(address(revenueCollector)), 30 ether);
    assertEq(token4.balanceOf(address(revenueCollector)), 20 ether);
  }

  function test_emergencyWithdraw() public {
    // fund revenue collector
    token0.setBalance(address(revenueCollector), 50 ether);
    vm.deal(address(revenueCollector), 50 ether);

    vm.expectRevert(); // revert error: AccessControlUnauthorizedAccount
    revenueCollector.emergencyWithdraw(address(token0), 10 ether, address(admin));

    vm.prank(manager);
    revenueCollector.emergencyWithdraw(address(token0), 10 ether, address(admin));

    // check balance
    assertEq(token0.balanceOf(address(revenueCollector)), 40 ether);

    address treasury = makeAddr("treasury");
    vm.prank(manager);
    revenueCollector.emergencyWithdraw(BNB_ADDRESS, 20 ether, treasury);

    // check balance
    assertEq(address(revenueCollector).balance, 30 ether);
    assertEq(treasury.balance, 20 ether);
  }
}

contract MockStableSwap {
  address public token0;
  address public token1;

  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function withdraw_admin_fees() public {
    if (token0 != BNB_ADDRESS) {
      ERC20Mock(token0).setBalance(address(this), 100 ether);
      ERC20Mock(token0).transfer(msg.sender, 100 ether);
    } else {
      // transfer BNB to msg.sender
      msg.sender.call{ value: 100 ether }("");
    }

    if (token1 != BNB_ADDRESS) {
      ERC20Mock(token1).setBalance(address(this), 100 ether);
      ERC20Mock(token1).transfer(msg.sender, 100 ether);
    } else {
      // transfer BNB to msg.sender
      msg.sender.call{ value: 100 ether }("");
    }
  }

  receive() external payable {}
}

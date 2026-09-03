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

  function test_batchAccrueVaultFees() public {
    MockMoolahVault vault1 = new MockMoolahVault();
    MockMoolahVault vault2 = new MockMoolahVault();

    address[] memory vaults = new address[](2);
    vaults[0] = address(vault1);
    vaults[1] = address(vault2);

    // only BOT can call
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    revenueCollector.batchAccrueVaultFees(vaults);

    vm.prank(bot);
    revenueCollector.batchAccrueVaultFees(vaults);

    // each vault received a deposit(0, revenueCollector) call
    assertEq(vault1.depositCalls(), 1);
    assertEq(vault1.lastAssets(), 0);
    assertEq(vault1.lastReceiver(), address(revenueCollector));
    assertEq(vault2.depositCalls(), 1);
    assertEq(vault2.lastAssets(), 0);
    assertEq(vault2.lastReceiver(), address(revenueCollector));
  }

  function test_accrueVaultFee() public {
    MockMoolahVault vault = new MockMoolahVault();

    vm.expectRevert(); // AccessControlUnauthorizedAccount
    revenueCollector.accrueVaultFee(address(vault));

    vm.prank(bot);
    revenueCollector.accrueVaultFee(address(vault));

    assertEq(vault.depositCalls(), 1);
    assertEq(vault.lastAssets(), 0);
    assertEq(vault.lastReceiver(), address(revenueCollector));
  }

  function test_batchAccrueVaultFees_invalidLength() public {
    address[] memory empty = new address[](0);
    vm.prank(bot);
    vm.expectRevert("invalid length");
    revenueCollector.batchAccrueVaultFees(empty);

    address[] memory tooMany = new address[](31);
    for (uint256 i = 0; i < 31; i++) {
      tooMany[i] = address(new MockMoolahVault());
    }
    vm.prank(bot);
    vm.expectRevert("invalid length");
    revenueCollector.batchAccrueVaultFees(tooMany);
  }

  function _redemption(
    address lpToken,
    uint256 minAmount0,
    uint256 minAmount1
  ) internal pure returns (RevenueCollector.V2LpRedemption memory) {
    return RevenueCollector.V2LpRedemption({ lpToken: lpToken, minAmount0: minAmount0, minAmount1: minAmount1 });
  }

  function test_redeemV2Lp() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));
    MockListaV2Pair pair = factory.createPair(address(token0), address(token1));
    // pair holds 100 token0 / 400 token1 backing 200 LP; the collector owns half of the supply
    pair.setReserves(100 ether, 400 ether);
    pair.setTotalSupply(200 ether);
    pair.setBalance(address(revenueCollector), 100 ether);

    (uint256 lpAmount, address t0, uint256 preview0, address t1, uint256 preview1) = revenueCollector.previewRedeemV2Lp(
      address(pair)
    );
    assertEq(lpAmount, 100 ether);
    assertEq(t0, address(token0));
    assertEq(t1, address(token1));
    assertEq(preview0, 50 ether);
    assertEq(preview1, 200 ether);

    // only BOT can redeem
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));

    vm.expectEmit(true, true, true, true);
    emit RevenueCollector.V2LpRedeemed(address(pair), 100 ether, address(token0), 50 ether, address(token1), 200 ether);
    vm.prank(bot);
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));

    // LP burned, underlying assets received
    assertEq(pair.balanceOf(address(revenueCollector)), 0);
    assertEq(pair.totalSupply(), 100 ether);
    assertEq(token0.balanceOf(address(revenueCollector)), 50 ether);
    assertEq(token1.balanceOf(address(revenueCollector)), 200 ether);
  }

  function test_redeemV2Lp_zeroBalance() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));
    MockListaV2Pair pair = factory.createPair(address(token0), address(token1));
    pair.setReserves(100 ether, 400 ether);
    pair.setTotalSupply(200 ether);

    (uint256 lpAmount, , uint256 preview0, , uint256 preview1) = revenueCollector.previewRedeemV2Lp(address(pair));
    assertEq(lpAmount, 0);
    assertEq(preview0, 0);
    assertEq(preview1, 0);

    // no-op instead of a revert
    vm.prank(bot);
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));

    assertEq(pair.burnCalls(), 0);
    assertEq(token0.balanceOf(address(revenueCollector)), 0);
    assertEq(token1.balanceOf(address(revenueCollector)), 0);
  }

  /// @dev The factory pays its protocol fee LP elsewhere, so the collector has no claim on it.
  function test_redeemV2Lp_feeToNotCollector() public {
    MockListaV2Factory factory = new MockListaV2Factory(makeAddr("otherFeeTo"));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));
    MockListaV2Pair pair = factory.createPair(address(token0), address(token1));
    pair.setReserves(100 ether, 400 ether);
    pair.setTotalSupply(200 ether);
    pair.setBalance(address(revenueCollector), 100 ether);

    vm.prank(bot);
    vm.expectRevert("not fee recipient");
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));

    vm.expectRevert("not fee recipient");
    revenueCollector.previewRedeemV2Lp(address(pair));

    // enabling feeTo on the factory makes the same LP redeemable
    factory.setFeeTo(address(revenueCollector));
    vm.prank(bot);
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));
    assertEq(token0.balanceOf(address(revenueCollector)), 50 ether);
  }

  function test_setV2Factory() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    assertEq(revenueCollector.v2Factory(), address(0));

    // only DEFAULT_ADMIN_ROLE can pin the factory
    vm.prank(manager);
    vm.expectRevert(); // AccessControlUnauthorizedAccount
    revenueCollector.setV2Factory(address(factory));

    vm.startPrank(admin);
    vm.expectRevert("zero address");
    revenueCollector.setV2Factory(address(0));

    vm.expectEmit(true, true, true, true);
    emit RevenueCollector.V2FactoryUpdated(address(0), address(factory));
    revenueCollector.setV2Factory(address(factory));
    assertEq(revenueCollector.v2Factory(), address(factory));

    vm.expectRevert("already set");
    revenueCollector.setV2Factory(address(factory));

    MockListaV2Factory factory2 = new MockListaV2Factory(address(revenueCollector));
    revenueCollector.setV2Factory(address(factory2));
    vm.stopPrank();

    assertEq(revenueCollector.v2Factory(), address(factory2));
  }

  function test_redeemV2Lp_factoryNotSet() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    MockListaV2Pair pair = factory.createPair(address(token0), address(token1));
    pair.setBalance(address(revenueCollector), 100 ether);

    vm.prank(bot);
    vm.expectRevert("v2 factory not set");
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));

    vm.expectRevert("v2 factory not set");
    revenueCollector.previewRedeemV2Lp(address(pair));
  }

  /// @dev A real pair, but from a factory other than the pinned one.
  function test_redeemV2Lp_foreignFactory() public {
    MockListaV2Factory pinned = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(pinned));

    MockListaV2Factory foreign = new MockListaV2Factory(address(revenueCollector));
    MockListaV2Pair pair = foreign.createPair(address(token0), address(token1));
    pair.setReserves(100 ether, 400 ether);
    pair.setTotalSupply(200 ether);
    pair.setBalance(address(revenueCollector), 100 ether);

    vm.prank(bot);
    vm.expectRevert("invalid lp token");
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 0));
  }

  /// @dev A pair-shaped contract the pinned factory does not know about is rejected.
  function test_redeemV2Lp_notRegisteredInFactory() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));
    MockListaV2Pair rogue = new MockListaV2Pair(address(token0), address(token1));
    rogue.setReserves(100 ether, 400 ether);
    rogue.setTotalSupply(200 ether);
    rogue.setBalance(address(revenueCollector), 100 ether);

    vm.prank(bot);
    vm.expectRevert("invalid lp token");
    revenueCollector.redeemV2Lp(_redemption(address(rogue), 0, 0));

    vm.expectRevert("invalid lp token");
    revenueCollector.previewRedeemV2Lp(address(rogue));
  }

  function test_batchRedeemV2Lps() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));

    MockListaV2Pair pair1 = factory.createPair(address(token0), address(token1));
    pair1.setReserves(100 ether, 400 ether);
    pair1.setTotalSupply(200 ether);
    pair1.setBalance(address(revenueCollector), 100 ether);

    // pair2 shares token0 with pair1 and holds no LP balance for the collector
    MockListaV2Pair pair2 = factory.createPair(address(token0), address(token4));
    pair2.setReserves(10 ether, 20 ether);
    pair2.setTotalSupply(100 ether);

    MockListaV2Pair pair3 = factory.createPair(address(token4), address(token1));
    pair3.setReserves(30 ether, 60 ether);
    pair3.setTotalSupply(300 ether);
    pair3.setBalance(address(revenueCollector), 150 ether);

    address[] memory lpTokens = new address[](3);
    lpTokens[0] = address(pair1);
    lpTokens[1] = address(pair2);
    lpTokens[2] = address(pair3);

    RevenueCollector.V2LpRedemption[] memory redemptions = new RevenueCollector.V2LpRedemption[](3);
    redemptions[0] = _redemption(lpTokens[0], 50 ether, 200 ether);
    redemptions[1] = _redemption(lpTokens[1], 0, 0);
    redemptions[2] = _redemption(lpTokens[2], 15 ether, 30 ether);

    vm.expectRevert(); // AccessControlUnauthorizedAccount
    revenueCollector.batchRedeemV2Lps(redemptions);

    vm.prank(bot);
    revenueCollector.batchRedeemV2Lps(redemptions);

    assertEq(pair1.burnCalls(), 1);
    assertEq(pair2.burnCalls(), 0); // skipped: zero balance
    assertEq(pair3.burnCalls(), 1);

    assertEq(token0.balanceOf(address(revenueCollector)), 50 ether);
    assertEq(token1.balanceOf(address(revenueCollector)), 230 ether); // 200 from pair1 + 30 from pair3
    assertEq(token4.balanceOf(address(revenueCollector)), 15 ether);
  }

  function test_batchRedeemV2Lps_invalidLength() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));

    vm.prank(bot);
    vm.expectRevert("invalid length");
    revenueCollector.batchRedeemV2Lps(new RevenueCollector.V2LpRedemption[](0));

    RevenueCollector.V2LpRedemption[] memory tooMany = new RevenueCollector.V2LpRedemption[](31);
    for (uint256 i = 0; i < 31; i++) {
      tooMany[i] = _redemption(address(factory.createPair(address(uint160(i + 1000)), address(token1))), 0, 0);
    }
    vm.prank(bot);
    vm.expectRevert("invalid length");
    revenueCollector.batchRedeemV2Lps(tooMany);
  }

  function test_redeemV2Lp_slippage() public {
    MockListaV2Factory factory = new MockListaV2Factory(address(revenueCollector));
    vm.prank(admin);
    revenueCollector.setV2Factory(address(factory));
    MockListaV2Pair pair = factory.createPair(address(token0), address(token1));
    pair.setReserves(100 ether, 400 ether);
    pair.setTotalSupply(200 ether);
    pair.setBalance(address(revenueCollector), 100 ether);

    // redeeming half the supply yields 50 token0 / 200 token1
    vm.prank(bot);
    vm.expectRevert("insufficient output");
    revenueCollector.redeemV2Lp(_redemption(address(pair), 50 ether + 1, 0));

    vm.prank(bot);
    vm.expectRevert("insufficient output");
    revenueCollector.redeemV2Lp(_redemption(address(pair), 0, 200 ether + 1));

    // exact expected amounts pass
    vm.prank(bot);
    revenueCollector.redeemV2Lp(_redemption(address(pair), 50 ether, 200 ether));
    assertEq(token0.balanceOf(address(revenueCollector)), 50 ether);
    assertEq(token1.balanceOf(address(revenueCollector)), 200 ether);
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

contract MockMoolahVault {
  uint256 public depositCalls;
  uint256 public lastAssets;
  address public lastReceiver;

  function deposit(uint256 assets, address receiver) external returns (uint256) {
    depositCalls += 1;
    lastAssets = assets;
    lastReceiver = receiver;
    return 0;
  }
}

contract MockListaV2Factory {
  address public feeTo;

  mapping(address => mapping(address => address)) public getPair;

  constructor(address _feeTo) {
    feeTo = _feeTo;
  }

  function setFeeTo(address _feeTo) external {
    feeTo = _feeTo;
  }

  function createPair(address tokenA, address tokenB) external returns (MockListaV2Pair pair) {
    pair = new MockListaV2Pair(tokenA, tokenB);
    getPair[tokenA][tokenB] = address(pair);
    getPair[tokenB][tokenA] = address(pair);
  }
}

contract MockListaV2Pair {
  address public token0;
  address public token1;

  uint112 private reserve0;
  uint112 private reserve1;
  uint256 public totalSupply;
  uint256 public burnCalls;

  mapping(address => uint256) public balanceOf;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function setReserves(uint112 _reserve0, uint112 _reserve1) external {
    reserve0 = _reserve0;
    reserve1 = _reserve1;
  }

  function setTotalSupply(uint256 _totalSupply) external {
    totalSupply = _totalSupply;
  }

  function setBalance(address account, uint256 amount) external {
    balanceOf[account] = amount;
  }

  function getReserves() external view returns (uint112, uint112, uint32) {
    return (reserve0, reserve1, 0);
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    require(balanceOf[msg.sender] >= amount, "insufficient balance");
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }

  /// @dev Mirrors Uniswap V2: burns the LP held by the pair and pays out a pro-rata share of reserves.
  function burn(address to) external returns (uint256 amount0, uint256 amount1) {
    burnCalls += 1;

    uint256 liquidity = balanceOf[address(this)];
    require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

    amount0 = (liquidity * reserve0) / totalSupply;
    amount1 = (liquidity * reserve1) / totalSupply;

    balanceOf[address(this)] = 0;
    totalSupply -= liquidity;
    reserve0 -= uint112(amount0);
    reserve1 -= uint112(amount1);

    ERC20Mock(token0).setBalance(address(this), amount0);
    ERC20Mock(token0).transfer(to, amount0);
    ERC20Mock(token1).setBalance(address(this), amount1);
    ERC20Mock(token1).transfer(to, amount1);
  }
}

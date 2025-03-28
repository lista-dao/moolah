// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";

import "./helpers/IntegrationTest.sol";

uint256 constant CAP2 = 100e18;
uint256 constant INITIAL_DEPOSIT = 4 * CAP2;

contract ReallocateWithdrawTest is IntegrationTest {
  using MarketParamsLib for MarketParams;
  using MoolahBalancesLib for IMoolah;
  using SharesMathLib for uint256;
  using UtilsLib for uint256;

  MarketAllocation[] internal allocations;

  function setUp() public override {
    super.setUp();

    _setCap(allMarkets[0], CAP2);
    _setCap(allMarkets[1], CAP2);
    _setCap(allMarkets[2], CAP2);

    _sortSupplyQueueIdleLast();

    loanToken.setBalance(SUPPLIER, INITIAL_DEPOSIT);

    vm.prank(SUPPLIER);
    vault.deposit(INITIAL_DEPOSIT, ONBEHALF);
  }

  function testReallocateWithdrawMax() public {
    allocations.push(MarketAllocation(allMarkets[0], 0));
    allocations.push(MarketAllocation(allMarkets[1], 0));
    allocations.push(MarketAllocation(allMarkets[2], 0));
    allocations.push(MarketAllocation(idleParams, type(uint256).max));

    vm.expectEmit();
    emit EventsLib.ReallocateWithdraw(
      ALLOCATOR_ADDR,
      allMarkets[0].id(),
      CAP2,
      moolah.position(allMarkets[0].id(), address(vault)).supplyShares
    );
    emit EventsLib.ReallocateWithdraw(
      ALLOCATOR_ADDR,
      allMarkets[1].id(),
      CAP2,
      moolah.position(allMarkets[1].id(), address(vault)).supplyShares
    );
    emit EventsLib.ReallocateWithdraw(
      ALLOCATOR_ADDR,
      allMarkets[2].id(),
      CAP2,
      moolah.position(allMarkets[2].id(), address(vault)).supplyShares
    );

    vm.prank(ALLOCATOR_ADDR);
    vault.reallocate(allocations);

    assertEq(moolah.position(allMarkets[0].id(), address(vault)).supplyShares, 0, "moolah.supplyShares(0)");
    assertEq(moolah.position(allMarkets[1].id(), address(vault)).supplyShares, 0, "moolah.supplyShares(1)");
    assertEq(moolah.position(allMarkets[2].id(), address(vault)).supplyShares, 0, "moolah.supplyShares(2)");
    assertEq(_idle(), INITIAL_DEPOSIT, "idle");
  }

  function testReallocateWithdrawMarketNotEnabled() public {
    ERC20Mock loanToken2 = new ERC20Mock("loan2", "B2");
    allMarkets[0].loanToken = address(loanToken2);

    vm.prank(MOOLAH_OWNER);
    moolah.createMarket(allMarkets[0]);

    loanToken2.setBalance(SUPPLIER, 1);

    vm.startPrank(SUPPLIER);
    loanToken2.approve(address(moolah), type(uint256).max);
    moolah.supply(allMarkets[0], 1, 0, address(vault), hex"");
    vm.stopPrank();

    allocations.push(MarketAllocation(allMarkets[0], 0));

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MarketNotEnabled.selector, allMarkets[0].id()));
    vault.reallocate(allocations);
  }

  function testReallocateWithdrawSupply(uint256[3] memory newAssets) public {
    uint256[3] memory totalSupplyAssets;
    uint256[3] memory totalSupplyShares;
    (totalSupplyAssets[0], totalSupplyShares[0], , ) = moolah.expectedMarketBalances(allMarkets[0]);
    (totalSupplyAssets[1], totalSupplyShares[1], , ) = moolah.expectedMarketBalances(allMarkets[1]);
    (totalSupplyAssets[2], totalSupplyShares[2], , ) = moolah.expectedMarketBalances(allMarkets[2]);

    newAssets[0] = bound(newAssets[0], 0, CAP2);
    newAssets[1] = bound(newAssets[1], 0, CAP2);
    newAssets[2] = bound(newAssets[2], 0, CAP2);

    uint256[3] memory assets;
    assets[0] = moolah.expectedSupplyAssets(allMarkets[0], address(vault));
    assets[1] = moolah.expectedSupplyAssets(allMarkets[1], address(vault));
    assets[2] = moolah.expectedSupplyAssets(allMarkets[2], address(vault));

    allocations.push(MarketAllocation(idleParams, 0));
    allocations.push(MarketAllocation(allMarkets[0], newAssets[0]));
    allocations.push(MarketAllocation(allMarkets[1], newAssets[1]));
    allocations.push(MarketAllocation(allMarkets[2], newAssets[2]));
    allocations.push(MarketAllocation(idleParams, type(uint256).max));

    uint256 expectedIdle = _idle() + 3 * CAP2 - newAssets[0] - newAssets[1] - newAssets[2];

    emit EventsLib.ReallocateWithdraw(ALLOCATOR_ADDR, idleParams.id(), 0, 0);

    if (newAssets[0] < assets[0]) emit EventsLib.ReallocateWithdraw(ALLOCATOR_ADDR, allMarkets[0].id(), 0, 0);
    else if (newAssets[0] > assets[0]) emit EventsLib.ReallocateSupply(ALLOCATOR_ADDR, allMarkets[0].id(), 0, 0);

    if (newAssets[1] < assets[1]) emit EventsLib.ReallocateWithdraw(ALLOCATOR_ADDR, allMarkets[1].id(), 0, 0);
    else if (newAssets[1] > assets[1]) emit EventsLib.ReallocateSupply(ALLOCATOR_ADDR, allMarkets[1].id(), 0, 0);

    if (newAssets[2] < assets[2]) emit EventsLib.ReallocateWithdraw(ALLOCATOR_ADDR, allMarkets[2].id(), 0, 0);
    else if (newAssets[2] > assets[2]) emit EventsLib.ReallocateSupply(ALLOCATOR_ADDR, allMarkets[2].id(), 0, 0);

    emit EventsLib.ReallocateSupply(ALLOCATOR_ADDR, idleParams.id(), 0, 0);

    vm.prank(ALLOCATOR_ADDR);
    vault.reallocate(allocations);

    assertEq(
      moolah.position(allMarkets[0].id(), address(vault)).supplyShares,
      newAssets[0] * SharesMathLib.VIRTUAL_SHARES,
      "moolah.supplyShares(0)"
    );
    assertApproxEqAbs(
      moolah.position(allMarkets[1].id(), address(vault)).supplyShares,
      newAssets[1] * SharesMathLib.VIRTUAL_SHARES,
      SharesMathLib.VIRTUAL_SHARES,
      "moolah.supplyShares(1)"
    );
    assertEq(
      moolah.position(allMarkets[2].id(), address(vault)).supplyShares,
      newAssets[2] * SharesMathLib.VIRTUAL_SHARES,
      "moolah.supplyShares(2)"
    );
    assertApproxEqAbs(_idle(), expectedIdle, 1, "idle");
  }

  function testReallocateWithdrawIncreaseSupply() public {
    _setCap(allMarkets[2], 3 * CAP2);

    allocations.push(MarketAllocation(allMarkets[0], 0));
    allocations.push(MarketAllocation(allMarkets[1], 0));
    allocations.push(MarketAllocation(allMarkets[2], 3 * CAP2));

    vm.expectEmit();
    emit EventsLib.ReallocateWithdraw(
      ALLOCATOR_ADDR,
      allMarkets[0].id(),
      CAP2,
      moolah.position(allMarkets[0].id(), address(vault)).supplyShares
    );
    emit EventsLib.ReallocateWithdraw(
      ALLOCATOR_ADDR,
      allMarkets[1].id(),
      CAP2,
      moolah.position(allMarkets[1].id(), address(vault)).supplyShares
    );
    emit EventsLib.ReallocateSupply(
      ALLOCATOR_ADDR,
      allMarkets[2].id(),
      3 * CAP2,
      3 * moolah.position(allMarkets[2].id(), address(vault)).supplyShares
    );

    vm.prank(ALLOCATOR_ADDR);
    vault.reallocate(allocations);

    assertEq(moolah.position(allMarkets[0].id(), address(vault)).supplyShares, 0, "moolah.supplyShares(0)");
    assertEq(moolah.position(allMarkets[1].id(), address(vault)).supplyShares, 0, "moolah.supplyShares(1)");
    assertEq(
      moolah.position(allMarkets[2].id(), address(vault)).supplyShares,
      3 * CAP2 * SharesMathLib.VIRTUAL_SHARES,
      "moolah.supplyShares(2)"
    );
  }

  function testReallocateUnauthorizedMarket(uint256[3] memory suppliedAssets) public {
    suppliedAssets[0] = bound(suppliedAssets[0], 1, CAP2);
    suppliedAssets[1] = bound(suppliedAssets[1], 1, CAP2);
    suppliedAssets[2] = bound(suppliedAssets[2], 1, CAP2);

    _setCap(allMarkets[1], 0);

    allocations.push(MarketAllocation(allMarkets[0], 0));
    allocations.push(MarketAllocation(allMarkets[1], 0));
    allocations.push(MarketAllocation(allMarkets[2], 0));

    allocations.push(MarketAllocation(allMarkets[0], suppliedAssets[0]));
    allocations.push(MarketAllocation(allMarkets[1], suppliedAssets[1]));
    allocations.push(MarketAllocation(allMarkets[2], suppliedAssets[2]));

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnauthorizedMarket.selector, allMarkets[1].id()));
    vault.reallocate(allocations);
  }

  function testReallocateSupplyCapExceeded() public {
    allocations.push(MarketAllocation(allMarkets[0], 0));
    allocations.push(MarketAllocation(allMarkets[1], 0));
    allocations.push(MarketAllocation(allMarkets[2], 0));

    allocations.push(MarketAllocation(allMarkets[0], CAP2 + 1));

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SupplyCapExceeded.selector, allMarkets[0].id()));
    vault.reallocate(allocations);
  }

  function testReallocateInconsistentReallocation(uint256 rewards) public {
    rewards = bound(rewards, 1, MAX_TEST_ASSETS);

    loanToken.setBalance(address(vault), rewards);

    _setCap(allMarkets[0], type(uint184).max);

    allocations.push(MarketAllocation(idleParams, 0));
    allocations.push(MarketAllocation(allMarkets[0], 2 * CAP2 + rewards));

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(ErrorsLib.InconsistentReallocation.selector);
    vault.reallocate(allocations);
  }
}

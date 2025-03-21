// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { stdError } from "forge-std/StdError.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./helpers/IntegrationTest.sol";

contract MarketTest is IntegrationTest {
  using MathLib for uint256;
  using MarketParamsLib for MarketParams;

  function setUp() public override {
    super.setUp();

    _setCap(allMarkets[0], CAP);
    _setCap(allMarkets[1], CAP);
    _setCap(allMarkets[2], CAP);
  }

  function testMintAllCapsReached() public {
    vm.prank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(new Id[](0));

    loanToken.setBalance(SUPPLIER, 1);

    vm.prank(SUPPLIER);
    loanToken.approve(address(vault), type(uint256).max);

    vm.expectRevert(ErrorsLib.AllCapsReached.selector);
    vm.prank(SUPPLIER);
    vault.mint(1, RECEIVER);
  }

  function testDepositAllCapsReached() public {
    vm.prank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(new Id[](0));

    loanToken.setBalance(SUPPLIER, 1);

    vm.prank(SUPPLIER);
    loanToken.approve(address(vault), type(uint256).max);

    vm.expectRevert(ErrorsLib.AllCapsReached.selector);
    vm.prank(SUPPLIER);
    vault.deposit(1, RECEIVER);
  }

  function testSubmitCapOverflow(uint256 seed, uint256 cap) public {
    MarketParams memory marketParams = _randomMarketParams(seed);
    cap = bound(cap, uint256(type(uint184).max) + 1, type(uint256).max);

    vm.prank(CURATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(184), cap));
    vault.setCap(marketParams, cap);
  }

  function testSubmitCapInconsistentAsset(MarketParams memory marketParams) public {
    vm.assume(marketParams.loanToken != address(loanToken));

    vm.prank(CURATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InconsistentAsset.selector, marketParams.id()));
    vault.setCap(marketParams, 0);
  }

  function testSubmitCapMarketNotCreated(MarketParams memory marketParams) public {
    marketParams.loanToken = address(loanToken);

    vm.assume(moolah.market(marketParams.id()).lastUpdate == 0);

    vm.prank(CURATOR_ADDR);
    vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
    vault.setCap(marketParams, 0);
  }

  function testSubmitCapAlreadySet() public {
    vm.prank(CURATOR_ADDR);
    vm.expectRevert(ErrorsLib.AlreadySet.selector);
    vault.setCap(allMarkets[0], CAP);
  }

  function testSubmitCapAlreadyPending() public {
    vm.prank(CURATOR_ADDR);
    vault.setCap(allMarkets[0], CAP + 1);

    vm.prank(CURATOR_ADDR);
    vm.expectRevert(ErrorsLib.AlreadySet.selector);
    vault.setCap(allMarkets[0], CAP + 1);
  }

  function testSubmitCapPendingRemoval() public {
    vm.startPrank(CURATOR_ADDR);
    vault.setCap(allMarkets[2], 0);
    vault.setMarketRemoval(allMarkets[2]);

    vm.expectRevert(ErrorsLib.PendingRemoval.selector);
    vault.setCap(allMarkets[2], CAP + 1);
  }

  function testSetSupplyQueue() public {
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = allMarkets[1].id();
    supplyQueue[1] = allMarkets[2].id();

    vm.expectEmit();
    emit EventsLib.SetSupplyQueue(ALLOCATOR_ADDR, supplyQueue);
    vm.prank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(supplyQueue);

    assertEq(Id.unwrap(vault.supplyQueue(0)), Id.unwrap(allMarkets[1].id()));
    assertEq(Id.unwrap(vault.supplyQueue(1)), Id.unwrap(allMarkets[2].id()));
  }

  function testSetSupplyQueueMaxQueueLengthExceeded() public {
    Id[] memory supplyQueue = new Id[](ConstantsLib.MAX_QUEUE_LENGTH + 1);

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(ErrorsLib.MaxQueueLengthExceeded.selector);
    vault.setSupplyQueue(supplyQueue);
  }

  function testAcceptCapMaxQueueLengthExceeded() public {
    for (uint256 i = 3; i < ConstantsLib.MAX_QUEUE_LENGTH - 1; ++i) {
      _setCap(allMarkets[i], CAP);
    }

    MarketParams memory marketParams = allMarkets[ConstantsLib.MAX_QUEUE_LENGTH];

    vm.startPrank(CURATOR_ADDR);
    vm.expectRevert(ErrorsLib.MaxQueueLengthExceeded.selector);
    vault.setCap(marketParams, CAP);
    vm.stopPrank();
  }

  function testSetSupplyQueueUnauthorizedMarket() public {
    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = allMarkets[3].id();

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnauthorizedMarket.selector, supplyQueue[0]));
    vault.setSupplyQueue(supplyQueue);
  }

  function testUpdateWithdrawQueue() public {
    uint256[] memory indexes = new uint256[](4);
    indexes[0] = 1;
    indexes[1] = 2;
    indexes[2] = 3;
    indexes[3] = 0;

    Id[] memory expectedWithdrawQueue = new Id[](4);
    expectedWithdrawQueue[0] = allMarkets[0].id();
    expectedWithdrawQueue[1] = allMarkets[1].id();
    expectedWithdrawQueue[2] = allMarkets[2].id();
    expectedWithdrawQueue[3] = idleParams.id();

    vm.expectEmit(address(vault));
    emit EventsLib.SetWithdrawQueue(ALLOCATOR_ADDR, expectedWithdrawQueue);
    vm.prank(ALLOCATOR_ADDR);
    vault.updateWithdrawQueue(indexes);

    assertEq(Id.unwrap(vault.withdrawQueue(0)), Id.unwrap(expectedWithdrawQueue[0]));
    assertEq(Id.unwrap(vault.withdrawQueue(1)), Id.unwrap(expectedWithdrawQueue[1]));
    assertEq(Id.unwrap(vault.withdrawQueue(2)), Id.unwrap(expectedWithdrawQueue[2]));
    assertEq(Id.unwrap(vault.withdrawQueue(3)), Id.unwrap(expectedWithdrawQueue[3]));
  }

  function testUpdateWithdrawQueueRemovingDisabledMarket() public {
    _setCap(allMarkets[2], 0);

    vm.prank(CURATOR_ADDR);
    vault.setMarketRemoval(allMarkets[2]);

    vm.warp(block.timestamp + TIMELOCK);

    uint256[] memory indexes = new uint256[](3);
    indexes[0] = 0;
    indexes[1] = 2;
    indexes[2] = 1;

    Id[] memory expectedWithdrawQueue = new Id[](3);
    expectedWithdrawQueue[0] = idleParams.id();
    expectedWithdrawQueue[1] = allMarkets[1].id();
    expectedWithdrawQueue[2] = allMarkets[0].id();

    vm.expectEmit();
    emit EventsLib.SetWithdrawQueue(ALLOCATOR_ADDR, expectedWithdrawQueue);
    vm.prank(ALLOCATOR_ADDR);
    vault.updateWithdrawQueue(indexes);

    assertEq(Id.unwrap(vault.withdrawQueue(0)), Id.unwrap(expectedWithdrawQueue[0]));
    assertEq(Id.unwrap(vault.withdrawQueue(1)), Id.unwrap(expectedWithdrawQueue[1]));
    assertEq(Id.unwrap(vault.withdrawQueue(2)), Id.unwrap(expectedWithdrawQueue[2]));
    assertFalse(vault.config(allMarkets[2].id()).enabled);
  }

  function testSubmitMarketRemoval() public {
    vm.startPrank(CURATOR_ADDR);
    vault.setCap(allMarkets[2], 0);

    vault.setMarketRemoval(allMarkets[2]);
    vm.stopPrank();

    assertEq(vault.config(allMarkets[2].id()).cap, 0);
    assertEq(vault.config(allMarkets[2].id()).removableAt, block.timestamp);
  }

  function testSubmitMarketRemovalPendingCap() public {
    vm.startPrank(CURATOR_ADDR);
    vault.setCap(allMarkets[2], 0);
    vault.setCap(allMarkets[2], vault.config(allMarkets[2].id()).cap + 1);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonZeroCap.selector));
    vault.setMarketRemoval(allMarkets[2]);
    vm.stopPrank();
  }

  function testSubmitMarketRemovalNonZeroCap() public {
    vm.startPrank(CURATOR_ADDR);
    vm.expectRevert(ErrorsLib.NonZeroCap.selector);
    vault.setMarketRemoval(allMarkets[2]);
    vm.stopPrank();
  }

  function testSubmitMarketRemovalAlreadyPending() public {
    vm.startPrank(CURATOR_ADDR);
    vault.setCap(allMarkets[2], 0);
    vault.setMarketRemoval(allMarkets[2]);
    vm.expectRevert(ErrorsLib.AlreadyPending.selector);
    vault.setMarketRemoval(allMarkets[2]);
    vm.stopPrank();
  }

  function testUpdateWithdrawQueueInvalidIndex() public {
    uint256[] memory indexes = new uint256[](4);
    indexes[0] = 1;
    indexes[1] = 2;
    indexes[2] = 3;
    indexes[3] = 4;

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(stdError.indexOOBError);
    vault.updateWithdrawQueue(indexes);
  }

  function testUpdateWithdrawQueueDuplicateMarket() public {
    uint256[] memory indexes = new uint256[](4);
    indexes[0] = 1;
    indexes[1] = 2;
    indexes[2] = 1;
    indexes[3] = 3;

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DuplicateMarket.selector, allMarkets[0].id()));
    vault.updateWithdrawQueue(indexes);
  }

  function testUpdateWithdrawQueueInvalidMarketRemovalNonZeroSupply() public {
    loanToken.setBalance(SUPPLIER, 1);

    vm.prank(SUPPLIER);
    vault.deposit(1, RECEIVER);

    uint256[] memory indexes = new uint256[](3);
    indexes[0] = 1;
    indexes[1] = 2;
    indexes[2] = 3;

    _setCap(idleParams, 0);

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidMarketRemovalNonZeroSupply.selector, idleParams.id()));
    vault.updateWithdrawQueue(indexes);
  }

  function testUpdateWithdrawQueueInvalidMarketRemovalNonZeroCap() public {
    uint256[] memory indexes = new uint256[](3);
    indexes[0] = 1;
    indexes[1] = 2;
    indexes[2] = 3;

    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidMarketRemovalNonZeroCap.selector, idleParams.id()));

    vm.prank(ALLOCATOR_ADDR);
    vault.updateWithdrawQueue(indexes);
  }

  function testUpdateWithdrawQueueInvalidMarketRemovalPendingCap(uint256 cap) public {
    cap = bound(cap, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

    _setCap(allMarkets[2], 0);
    vm.prank(CURATOR_ADDR);
    vault.setCap(allMarkets[2], cap);

    uint256[] memory indexes = new uint256[](3);
    indexes[0] = 0;
    indexes[1] = 2;
    indexes[2] = 1;

    vm.prank(ALLOCATOR_ADDR);
    vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidMarketRemovalNonZeroCap.selector, allMarkets[2].id()));
    vault.updateWithdrawQueue(indexes);
  }

  function testEnableMarketWithLiquidity(uint256 deposited, uint256 additionalSupply, uint256 blocks) public {
    deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
    additionalSupply = bound(additionalSupply, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
    blocks = _boundBlocks(blocks);

    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = allMarkets[0].id();

    _setCap(allMarkets[0], deposited);

    vm.prank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(supplyQueue);

    loanToken.setBalance(SUPPLIER, deposited + additionalSupply);

    vm.startPrank(SUPPLIER);
    vault.deposit(deposited, ONBEHALF);
    moolah.supply(allMarkets[3], additionalSupply, 0, address(vault), hex"");
    vm.stopPrank();

    uint256 collateral = uint256(MAX_TEST_ASSETS).wDivUp(allMarkets[0].lltv);
    collateralToken.setBalance(BORROWER, collateral);

    vm.startPrank(BORROWER);
    moolah.supplyCollateral(allMarkets[0], collateral, BORROWER, hex"");
    moolah.borrow(allMarkets[0], deposited, 0, BORROWER, BORROWER);
    vm.stopPrank();

    _forward(blocks);

    _setCap(allMarkets[3], CAP);

    assertEq(vault.lastTotalAssets(), deposited + additionalSupply);
  }
}

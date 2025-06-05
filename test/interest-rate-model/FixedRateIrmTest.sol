// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/Test.sol";

import "interest-rate-model/FixedRateIrm.sol";

contract FixedRateIrmTest is Test {
  using MarketParamsLib for MarketParams;

  event SetBorrowRate(Id indexed id, int256 newBorrowRate);

  FixedRateIrm public fixedRateIrm;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");

  function setUp() external {
    FixedRateIrm impl = new FixedRateIrm();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager)
    );

    fixedRateIrm = FixedRateIrm(address(proxy));
  }

  function testSetBorrowRate(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());

    vm.prank(manager);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
    assertEq(fixedRateIrm.borrowRateStored(id), int256(newBorrowRate));
  }

  function testSetBorrowRateEvent(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());

    vm.expectEmit(true, true, true, true, address(fixedRateIrm));
    emit SetBorrowRate(id, int256(newBorrowRate));
    vm.startPrank(manager);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
  }

  function testSetBorrowRateAlreadySet(Id id, int256 newBorrowRate1) external {
    newBorrowRate1 = fixedRateIrm.MAX_BORROW_RATE() / 2;

    vm.startPrank(manager);
    fixedRateIrm.setBorrowRate(id, newBorrowRate1);
    vm.expectRevert(bytes(RATE_SET));
    fixedRateIrm.setBorrowRate(id, newBorrowRate1);
  }

  function testSetBorrowRateRateZero(Id id) external {
    vm.expectRevert(bytes(RATE_INVALID));
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(id, 0);
  }

  function testSetBorrowRateTooHigh(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, fixedRateIrm.MAX_BORROW_RATE() + 1, type(int256).max);
    vm.expectRevert(bytes(RATE_TOO_HIGH));
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
  }

  function testBorrowRate(MarketParams memory marketParams, Market memory market, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(marketParams.id(), newBorrowRate);
    assertEq(fixedRateIrm.borrowRate(marketParams, market), uint256(newBorrowRate));
  }

  function testBorrowRateRateNotSet(MarketParams memory marketParams, Market memory market) external {
    vm.expectRevert(bytes(RATE_INVALID));
    fixedRateIrm.borrowRate(marketParams, market);
  }

  function testBorrowRateView(MarketParams memory marketParams, Market memory market, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(marketParams.id(), newBorrowRate);
    assertEq(fixedRateIrm.borrowRateView(marketParams, market), uint256(newBorrowRate));
  }

  function testBorrowRateViewRateNotSet(MarketParams memory marketParams, Market memory market) external {
    vm.expectRevert(bytes(RATE_INVALID));
    fixedRateIrm.borrowRateView(marketParams, market);
  }
}

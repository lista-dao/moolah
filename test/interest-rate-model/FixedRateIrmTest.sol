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
  address bot = makeAddr("bot");

  function setUp() external {
    FixedRateIrm impl = new FixedRateIrm();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager)
    );

    fixedRateIrm = FixedRateIrm(address(proxy));

    vm.startPrank(admin);
    fixedRateIrm.grantRole(fixedRateIrm.BOT(), bot);
    vm.stopPrank();
  }

  function testSetBorrowRate(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());

    vm.prank(bot);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
    assertEq(fixedRateIrm.borrowRateStored(id), int256(newBorrowRate));
  }

  function testSetBorrowRateEvent(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());

    vm.expectEmit(true, true, true, true, address(fixedRateIrm));
    emit SetBorrowRate(id, int256(newBorrowRate));
    vm.startPrank(bot);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
  }

  function testSetBorrowRateAlreadySet(Id id, int256 newBorrowRate1) external {
    newBorrowRate1 = fixedRateIrm.MAX_BORROW_RATE() / 2;

    vm.startPrank(bot);
    fixedRateIrm.setBorrowRate(id, newBorrowRate1);
    vm.expectRevert(bytes(RATE_SET));
    fixedRateIrm.setBorrowRate(id, newBorrowRate1);
  }

  function testSetBorrowRateRateZero(Id id) external {
    vm.expectRevert(bytes(RATE_INVALID));
    vm.prank(bot);
    fixedRateIrm.setBorrowRate(id, 0);
  }

  function testSetBorrowRateTooHigh(Id id, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, fixedRateIrm.MAX_BORROW_RATE() + 1, type(int256).max);
    vm.expectRevert(bytes(RATE_TOO_HIGH));
    vm.prank(bot);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
  }

  function testBorrowRate(MarketParams memory marketParams, Market memory market, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());
    vm.prank(bot);
    fixedRateIrm.setBorrowRate(marketParams.id(), newBorrowRate);
    assertEq(fixedRateIrm.borrowRate(marketParams, market), uint256(newBorrowRate));
  }

  function testBorrowRateRateNotSet(MarketParams memory marketParams, Market memory market) external {
    vm.expectRevert(bytes(RATE_INVALID));
    fixedRateIrm.borrowRate(marketParams, market);
  }

  function testBorrowRateView(MarketParams memory marketParams, Market memory market, int256 newBorrowRate) external {
    newBorrowRate = bound(newBorrowRate, 1, fixedRateIrm.MAX_BORROW_RATE());
    vm.prank(bot);
    fixedRateIrm.setBorrowRate(marketParams.id(), newBorrowRate);
    assertEq(fixedRateIrm.borrowRateView(marketParams, market), uint256(newBorrowRate));
  }

  function testBorrowRateViewRateNotSet(MarketParams memory marketParams, Market memory market) external {
    vm.expectRevert(bytes(RATE_INVALID));
    fixedRateIrm.borrowRateView(marketParams, market);
  }

  function testUpdateMinCap(Id id) external {
    uint256 newCap = uint256(1 ether) / uint256(365 days);
    vm.startPrank(manager);
    fixedRateIrm.updateMinCap(newCap);
    vm.stopPrank();
    assertEq(fixedRateIrm.minCap(), newCap);
  }

  function testUpdateRateCap(Id id) external {
    uint256 newCap = uint256(1 ether) / uint256(365 days);
    vm.startPrank(bot);
    fixedRateIrm.updateRateCap(id, newCap);
    vm.stopPrank();
    assertEq(fixedRateIrm.rateCap(id), newCap);
  }

  function testUpdateRateFloor(Id id) external {
    uint256 newFloor = uint256(1 ether) / uint256(365 days);
    vm.startPrank(bot);
    fixedRateIrm.updateRateFloor(id, newFloor);
    vm.stopPrank();
    assertEq(fixedRateIrm.rateFloor(id), newFloor);
  }

  function testBorrowRateWithCapAndFloor(MarketParams memory marketPrams, Market memory market) external {
    Id id = marketPrams.id();
    uint256 newCap = uint256(0.1 ether) / uint256(365 days);
    uint256 newFloor = uint256(0.01 ether) / uint256(365 days);
    int256 newBorrowRate = int256(0.001 ether) / int256(365 days);
    uint256 newMinCap = uint256(0.2 ether) / uint256(365 days);
    vm.startPrank(bot);
    fixedRateIrm.updateRateCap(id, newCap);
    fixedRateIrm.updateRateFloor(id, newFloor);
    vm.expectRevert("rate below floor");
    fixedRateIrm.setBorrowRate(id, newBorrowRate);

    newBorrowRate = int256(0.2 ether) / int256(365 days);
    vm.expectRevert("rate exceeds cap");
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
    vm.stopPrank();

    vm.startPrank(manager);
    fixedRateIrm.updateMinCap(newMinCap);
    vm.stopPrank();

    vm.startPrank(bot);
    newBorrowRate = int256(0.05 ether) / int256(365 days);
    fixedRateIrm.setBorrowRate(id, newBorrowRate);
    vm.stopPrank();

    assertEq(fixedRateIrm.borrowRateView(marketPrams, market), uint256(newBorrowRate));
  }
}

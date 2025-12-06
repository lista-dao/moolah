// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/Test.sol";

import "interest-rate-model/FixedRateIrm.sol";

contract AlpahIrmMainnetTest is Test {
  using MarketParamsLib for MarketParams;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address alphaIrm = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;

  FixedRateIrm fixedRateIrm = FixedRateIrm(alphaIrm);

  bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  function setUp() external {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    address impl = address(new FixedRateIrm());

    vm.startPrank(admin);
    UUPSUpgradeable proxy = UUPSUpgradeable(alphaIrm);
    proxy.upgradeToAndCall(impl, bytes(""));
    assertEq(getImplementation(alphaIrm), impl);
    fixedRateIrm = FixedRateIrm(alphaIrm);

    fixedRateIrm.grantRole(fixedRateIrm.MANAGER(), manager);
    fixedRateIrm.grantRole(fixedRateIrm.BOT(), manager);
    vm.stopPrank();
  }

  function test_roleAdmin() public view {
    assertTrue(fixedRateIrm.hasRole(fixedRateIrm.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(fixedRateIrm.hasRole(fixedRateIrm.MANAGER(), manager));

    assertEq(fixedRateIrm.getRoleAdmin(fixedRateIrm.DEFAULT_ADMIN_ROLE()), fixedRateIrm.DEFAULT_ADMIN_ROLE());
    assertEq(fixedRateIrm.getRoleAdmin(fixedRateIrm.MANAGER()), fixedRateIrm.DEFAULT_ADMIN_ROLE());
  }

  function test_setBorrowRate() public {
    Id id = Id.wrap(bytes32(0x00));
    int256 rate = 0.05 ether / int256(365 days); // 5% annual interest rate
    vm.expectRevert();
    fixedRateIrm.setBorrowRate(id, rate);
    vm.startPrank(manager);
    fixedRateIrm.setBorrowRate(id, rate);

    assertEq(fixedRateIrm.borrowRateStored(id), rate);
    vm.stopPrank();
  }

  function test_borrowRateView() public {
    int256 rate = 0.05 ether / int256(365 days); // 5% annual interest rate

    MarketParams memory marketParams;
    Market memory market;
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(marketParams.id(), rate);

    assertEq(fixedRateIrm.borrowRateView(marketParams, market), uint256(rate));
  }

  function test_borrowRate() public {
    int256 rate = 0.05 ether / int256(365 days); // 5% annual interest rate

    MarketParams memory marketParams;
    Market memory market;
    vm.prank(manager);
    fixedRateIrm.setBorrowRate(marketParams.id(), rate);

    assertEq(fixedRateIrm.borrowRate(marketParams, market), uint256(rate));
  }

  function getImplementation(address _proxyAddress) public view returns (address) {
    bytes32 implSlot = vm.load(_proxyAddress, IMPLEMENTATION_SLOT);
    return address(uint160(uint256(implSlot)));
  }
}

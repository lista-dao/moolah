// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// exec-verify PROD-PATH validation: prove the 708 rollout works through the REAL mainnet
// governance path — a 24h TimelockController — not a direct admin call. This is the
// "testnet-OK but prod-path-differs" class of divergence that only a mainnet fork surfaces.
//
// Real mainnet state: RevenueCollector admin = TimelockController 0x07D274 (getMinDelay=86400).
// Both _authorizeUpgrade and setV2Factory are onlyRole(DEFAULT_ADMIN_ROLE) = the timelock,
// so BOTH must go through schedule -> wait 24h -> execute (batched here).
//
// Run: BSC_RPC=<url> forge test --match-contract RevenueCollectorTimelockPathForkTest -vvv

import "forge-std/Test.sol";
import { RevenueCollector } from "../../src/revenue/RevenueCollector.sol";

interface ITimelock {
  function getMinDelay() external view returns (uint256);
  function PROPOSER_ROLE() external view returns (bytes32);
  function EXECUTOR_ROLE() external view returns (bytes32);
  function grantRole(bytes32 role, address account) external;
  function scheduleBatch(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
  ) external;
  function executeBatch(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata payloads,
    bytes32 predecessor,
    bytes32 salt
  ) external payable;
}

interface IUUPS {
  function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
interface IERC20Min { function balanceOf(address) external view returns (uint256); }

contract RevenueCollectorTimelockPathForkTest is Test {
  address constant COLLECTOR = 0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // real admin (24h TL)
  address constant BOT = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant FACTORY = 0x28F5E6C71C7541b1C6523351AE331CcAfC443626;
  address constant PAIR = 0x61aaCAc46F8d41f37BeB4935fc8D29b217613637;

  RevenueCollector coll = RevenueCollector(payable(COLLECTOR));

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"));
  }

  /// @dev The real rollout: batch [upgrade, setV2Factory] through the 24h timelock, then redeem.
  function test_fork_real_timelock_rollout() public {
    ITimelock tl = ITimelock(TIMELOCK);
    uint256 delay = tl.getMinDelay();
    assertEq(delay, 86400, "expected 24h timelock");

    // On the fork, impersonate the timelock (self-admin) to grant ourselves proposer/executor.
    vm.startPrank(TIMELOCK);
    tl.grantRole(tl.PROPOSER_ROLE(), address(this));
    tl.grantRole(tl.EXECUTOR_ROLE(), address(this));
    vm.stopPrank();

    // Deploy the new impl (in reality this address is deployed first, then scheduled).
    RevenueCollector newImpl = new RevenueCollector();

    // Batch operation: (1) upgrade proxy, (2) setV2Factory — both hit the collector, both timelocked.
    address[] memory targets = new address[](2);
    uint256[] memory values = new uint256[](2);
    bytes[] memory payloads = new bytes[](2);
    targets[0] = COLLECTOR;
    payloads[0] = abi.encodeWithSelector(IUUPS.upgradeToAndCall.selector, address(newImpl), bytes(""));
    targets[1] = COLLECTOR;
    payloads[1] = abi.encodeWithSelector(RevenueCollector.setV2Factory.selector, FACTORY);

    bytes32 salt = keccak256("task708-rollout");

    // schedule
    tl.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);

    // executing before the delay must fail (proves the 24h gate is real)
    vm.expectRevert();
    tl.executeBatch(targets, values, payloads, bytes32(0), salt);

    // wait out the real delay, then execute
    vm.warp(block.timestamp + delay);
    tl.executeBatch(targets, values, payloads, bytes32(0), salt);

    // governance path landed the upgrade + wiring
    assertEq(coll.v2Factory(), FACTORY, "setV2Factory via timelock");
    assertTrue(coll.hasRole(coll.BOT(), BOT), "roles survived upgrade");

    // now BOT can redeem the real accrued LP
    uint256 lp = IERC20Min(PAIR).balanceOf(COLLECTOR);
    assertGt(lp, 0, "real accrued LP present");
    vm.prank(BOT);
    coll.redeemV2Lp(RevenueCollector.V2LpRedemption({ lpToken: PAIR, minAmount0: 0, minAmount1: 0 }));
    assertEq(IERC20Min(PAIR).balanceOf(COLLECTOR), 0, "redeemed through full prod path");

    emit log_named_uint("rolled out via 24h timelock + redeemed real LP", lp);
  }
}

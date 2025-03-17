//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/governance/TimelockController.sol";

contract TimeLock is TimelockController {

  uint256 public immutable MIN_DELAY;

  constructor(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin
  ) TimelockController(minDelay, proposers, executors, admin) {
    MIN_DELAY = 1 days;
    require(minDelay >= MIN_DELAY, "TimeLock: insufficient delay");
  }

  function schedule(
    address target,
    uint256 value,
    bytes calldata data,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
  ) public override {
    require(delay >= MIN_DELAY, "Timelock: insufficient delay");
    super.schedule(target, value, data, predecessor, salt, delay);
  }

  function scheduleBatch(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
  ) public override {
    require(delay >= MIN_DELAY, "Timelock: insufficient delay");
    super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
  }
}

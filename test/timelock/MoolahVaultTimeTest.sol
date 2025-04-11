// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;


import { Test, console } from "forge-std/Test.sol";

import { TimeLock } from "timelock/TimeLock.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract TimeLockTest is Test {
  TimeLock timeLock = TimeLock(payable(0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85));
  MoolahVault vault = MoolahVault(0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0);
  address proposer = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  bytes32 constant CURATOR = 0x0aec9b08bc8c2cb62a91f52d33e3d77da4b3f3a63fc8b542a93abe3902ba929c;

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_transferRole() public {
    address[] memory targets = new address[](2);
    targets[0] = address(vault);
    targets[1] = address(vault);

    uint256[] memory values = new uint256[](2);
    values[0] = 0;
    values[1] = 0;

    bytes[] memory payloads = new bytes[](2);
    payloads[0] = hex"2f2ff15d0aec9b08bc8c2cb62a91f52d33e3d77da4b3f3a63fc8b542a93abe3902ba929c0000000000000000000000002e2807f88c381cb0cc55c808a751fc1e3fccbb85";
    payloads[1] = hex"d547741f0aec9b08bc8c2cb62a91f52d33e3d77da4b3f3a63fc8b542a93abe3902ba929c0000000000000000000000008d388136d578dcd791d081c6042284ced6d9b0c6";

    bytes32 predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000000;
    uint256 delay = 86400;

    address[] memory curators = vault.getRoleMembers(CURATOR);
    for (uint256 i = 0; i < curators.length; i++) {
      console.log(curators[i]);
    }

    vm.startPrank(proposer);
    timeLock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    vm.stopPrank();

    skip(delay);

    vm.startPrank(proposer);
    timeLock.executeBatch(targets, values, payloads, predecessor, salt);
    vm.stopPrank();

    console.log("transfer role done!");

    curators = vault.getRoleMembers(CURATOR);
    for (uint256 i = 0; i < curators.length; i++) {
      console.log(curators[i]);
    }
  }

  function test_setFeeRecipient() public {
    address target = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;

    bytes memory data = hex"e74b981b00000000000000000000000044dc4cc17081b05a50aa970ed8ddd6c047bd549b";

    bytes32 predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000001;
    uint256 delay = 86400;

    vm.startPrank(proposer);
    timeLock.schedule(target, 0, data, predecessor, salt, delay);
    vm.stopPrank();

    skip(delay);

    vm.startPrank(proposer);
    timeLock.execute(target, 0, data, predecessor, salt);
    vm.stopPrank();

    console.log("set fee recipient done!");

    address feeRecipient = vault.feeRecipient();
    console.log("feeRecipient", feeRecipient);
  }

}

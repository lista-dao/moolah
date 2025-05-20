// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;


import { Test, console } from "forge-std/Test.sol";

import { TimeLock } from "timelock/TimeLock.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { Id } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultTimeLockTest is Test {
  TimeLock timeLock = TimeLock(payable(0x2e2807F88C381Cb0CC55c808a751fC1E3fcCbb85));
  MoolahVault vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  address proposer = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  bytes32 constant CURATOR = 0x0aec9b08bc8c2cb62a91f52d33e3d77da4b3f3a63fc8b542a93abe3902ba929c;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_removeMarket() public {
    address[] memory targets = new address[](3);
    targets[0] = address(vault);
    targets[1] = address(vault);
    targets[2] = address(vault);

    uint256[] memory values = new uint256[](3);
    values[0] = 0;
    values[1] = 0;
    values[2] = 0;

    bytes[] memory payloads = new bytes[](3);
    payloads[0] = hex"d3ac290c00000000000000000000000055d398326f99059ff775485246999027b3197955000000000000000000000000dd809435ba6c9d6903730f923038801781ca66ce00000000000000000000000089852c82e4a7aa41c7691b374d5d5ef8487ec370000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000cb2bba6f17b80000000000000000000000000000000000000000000000000000000000000000000";
    payloads[1] = hex"41c68e4800000000000000000000000055d398326f99059ff775485246999027b3197955000000000000000000000000dd809435ba6c9d6903730f923038801781ca66ce00000000000000000000000089852c82e4a7aa41c7691b374d5d5ef8487ec370000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000cb2bba6f17b8000";
    payloads[2] = hex"d3ac290c00000000000000000000000055d398326f99059ff775485246999027b3197955000000000000000000000000dd809435ba6c9d6903730f923038801781ca66ce0000000000000000000000006961fe6bb5292279bbe72c7acfb9fdf7d3fbed13000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000cb2bba6f17b8000000000000000000000000000000000000000000000108b2a2c28029094000000";

    bytes32 predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000009;
    uint256 delay = 86400;


    Id oldId = Id.wrap(hex"b9db2f7e903ccab0b7f715500f925d3e3def42a364a5ebe6af52f4b10917bb03");
    Id newId = Id.wrap(hex"417eef8a15b54c61c64026d13ff067611579d95d392c969cac919115b5a379a2");

    (uint184 oldCap,bool oldEnabled,) = vault.config(oldId);
    (uint184 newCap,bool newEnabled,) = vault.config(newId);

    console.log("old", oldEnabled);
    console.log("new", newEnabled);
    console.log("oldCap", oldCap);
    console.log("newCap", newCap);

    vm.startPrank(proposer);
    timeLock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    vm.stopPrank();

    skip(delay);

    vm.startPrank(proposer);
    timeLock.executeBatch(targets, values, payloads, predecessor, salt);
    vm.stopPrank();

    vm.startPrank(allocator);
    removeMarket(oldId);
    vm.stopPrank();

    console.log("execute done!");

    (oldCap,oldEnabled,) = vault.config(oldId);
    (newCap,newEnabled,) = vault.config(newId);

    console.log("old", oldEnabled);
    console.log("new", newEnabled);
    console.log("oldCap", oldCap);
    console.log("newCap", newCap);

    for (uint256 i = 0; i < vault.supplyQueueLength(); i++) {
      console.logBytes32(Id.unwrap(vault.supplyQueue(i)));
    }
  }

  function removeMarket(Id marketId) internal {
    uint256 oldLen = vault.withdrawQueueLength();
    uint256 newLen = oldLen - 1;
    uint256[] memory indexes = new uint256[](newLen);
    uint256 removeIndex = 0;

    for ((uint256 i, uint256 j) = (0, 0); i < oldLen; i++) {
      if (Id.unwrap(vault.withdrawQueue(i)) != Id.unwrap(marketId)) {
        indexes[j] = i;
        j++;
      } else {
        removeIndex = i;
      }
    }

    console.log("removeIndex", removeIndex);


    vault.updateWithdrawQueue(indexes);

    for (uint256 i; i < indexes.length; i++) {
      console.log(indexes[i]);
    }

    console.log("supply queue length", vault.supplyQueueLength());
    console.logBytes32(Id.unwrap(vault.supplyQueue(4)));

  }

}

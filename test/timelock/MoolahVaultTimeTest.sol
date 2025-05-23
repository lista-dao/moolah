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


  address vault1 = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;
  address vault2 = 0xE46b8E65006e6450bdd8cb7D3274AB4F76f4C705;
  address vault3 = 0x6d6783C146F2B0B2774C1725297f1845dc502525;
  address vault4 = 0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627;

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_removeMarket() public {
    address[] memory targets = new address[](8);
    targets[0] = vault1;
    targets[1] = vault1;
    targets[2] = vault2;
    targets[3] = vault2;
    targets[4] = vault3;
    targets[5] = vault3;
    targets[6] = vault4;
    targets[7] = vault4;

    uint256[] memory values = new uint256[](8);
    values[0] = 0;
    values[1] = 0;
    values[2] = 0;
    values[3] = 0;
    values[4] = 0;
    values[5] = 0;
    values[6] = 0;
    values[7] = 0;

    bytes[] memory payloads = new bytes[](8);
    payloads[0] = hex"d3ac290c000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c000000000000000000000000a2e3356610840701bdf5611a53974510ae27e2e1000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000000a968163f0a57b400000";
    payloads[1] = hex"d3ac290c000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c00000000000000000000000026c5e01524d2e6280a48f2c50ff6de7e52e9611c000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000000a968163f0a57b400000";
    payloads[2] = hex"d3ac290c0000000000000000000000007130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c000000000000000000000000a2e3356610840701bdf5611a53974510ae27e2e1000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000001b1ae4d6e2ef500000";
    payloads[3] = hex"d3ac290c0000000000000000000000007130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c00000000000000000000000026c5e01524d2e6280a48f2c50ff6de7e52e9611c000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000001b1ae4d6e2ef500000";
    payloads[4] = hex"d3ac290c00000000000000000000000055d398326f99059ff775485246999027b3197955000000000000000000000000a2e3356610840701bdf5611a53974510ae27e2e1000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000108b2a2c28029094000000";
    payloads[5] = hex"d3ac290c00000000000000000000000055d398326f99059ff775485246999027b319795500000000000000000000000026c5e01524d2e6280a48f2c50ff6de7e52e9611c000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000108b2a2c28029094000000";
    payloads[6] = hex"d3ac290c0000000000000000000000008d0d000ee44948fc98c9b98a4fa4921476f08b0d000000000000000000000000a2e3356610840701bdf5611a53974510ae27e2e1000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000108b2a2c28029094000000";
    payloads[7] = hex"d3ac290c0000000000000000000000008d0d000ee44948fc98c9b98a4fa4921476f08b0d00000000000000000000000026c5e01524d2e6280a48f2c50ff6de7e52e9611c000000000000000000000000f3afd82a4071f272f403dc176916141f44e6c750000000000000000000000000fe7dae87ebb11a7beb9f534bb23267992d9cde7c0000000000000000000000000000000000000000000000000b1a2bc2ec500000000000000000000000000000000000000000000000108b2a2c28029094000000";

    bytes32 predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000010;
    uint256 delay = 86400;


//    Id oldId = Id.wrap(hex"b9db2f7e903ccab0b7f715500f925d3e3def42a364a5ebe6af52f4b10917bb03");
//    Id newId = Id.wrap(hex"417eef8a15b54c61c64026d13ff067611579d95d392c969cac919115b5a379a2");
//
//    (uint184 oldCap,bool oldEnabled,) = vault.config(oldId);
//    (uint184 newCap,bool newEnabled,) = vault.config(newId);
//
//    console.log("old", oldEnabled);
//    console.log("new", newEnabled);
//    console.log("oldCap", oldCap);
//    console.log("newCap", newCap);

//    vm.startPrank(proposer);
//    timeLock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
//    vm.stopPrank();
//
    skip(delay);

    vm.startPrank(proposer);
    timeLock.executeBatch(targets, values, payloads, predecessor, salt);
    vm.stopPrank();

//    vm.startPrank(allocator);
//    removeMarket(oldId);
//    vm.stopPrank();
//
//    console.log("execute done!");
//
//    (oldCap,oldEnabled,) = vault.config(oldId);
//    (newCap,newEnabled,) = vault.config(newId);
//
//    console.log("old", oldEnabled);
//    console.log("new", newEnabled);
//    console.log("oldCap", oldCap);
//    console.log("newCap", newCap);
//
//    for (uint256 i = 0; i < vault.supplyQueueLength(); i++) {
//      console.logBytes32(Id.unwrap(vault.supplyQueue(i)));
//    }
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

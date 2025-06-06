// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./helpers/IntegrationTest.sol";

contract RoleTest is IntegrationTest {
  using MarketParamsLib for MarketParams;

  function testSetCurator() public {
    address newCurator = makeAddr("Curator2");

    vm.prank(OWNER);
    vault.grantRole(CURATOR_ROLE, newCurator);

    assertTrue(vault.hasRole(CURATOR_ROLE, newCurator), "curator");
  }

  function testSetAllocator() public {
    address newAllocator = makeAddr("Allocator2");

    vm.prank(OWNER);
    vault.grantRole(ALLOCATOR_ROLE, newAllocator);

    assertTrue(vault.hasRole(ALLOCATOR_ROLE, newAllocator), "isAllocator");
  }

  function testUnsetAllocator() public {
    vm.prank(OWNER);
    vault.revokeRole(ALLOCATOR_ROLE, ALLOCATOR_ADDR);

    assertFalse(vault.hasRole(ALLOCATOR_ROLE, ALLOCATOR_ADDR), "isAllocator");
  }

  function testOwnerFunctionsShouldRevertWhenNotOwner(address caller) public {
    vm.assume(!vault.hasRole(MANAGER_ROLE, caller));

    vm.startPrank(caller);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, DEFAULT_ADMIN_ROLE)
    );
    vault.grantRole(CURATOR_ROLE, caller);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, MANAGER_ROLE)
    );
    vault.grantRole(ALLOCATOR_ROLE, caller);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, MANAGER_ROLE)
    );
    vault.setFee(1);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, MANAGER_ROLE)
    );
    vault.setFeeRecipient(caller);

    vm.stopPrank();
  }

  function testCuratorFunctionsShouldRevertWhenNotCuratorRole(address caller) public {
    vm.assume(!vault.hasRole(MANAGER_ROLE, caller) && !vault.hasRole(CURATOR_ROLE, caller));

    vm.startPrank(caller);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, CURATOR_ROLE)
    );
    vault.setCap(allMarkets[0], CAP);

    vm.stopPrank();
  }

  function testAllocatorFunctionsShouldRevertWhenNotAllocatorRole(address caller) public {
    vm.assume(
      !vault.hasRole(ALLOCATOR_ROLE, caller) &&
        !vault.hasRole(MANAGER_ROLE, caller) &&
        !vault.hasRole(CURATOR_ROLE, caller)
    );

    vm.startPrank(caller);

    Id[] memory supplyQueue;
    MarketAllocation[] memory allocation;
    uint256[] memory withdrawQueueFromRanks;

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ALLOCATOR_ROLE)
    );
    vault.setSupplyQueue(supplyQueue);

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ALLOCATOR_ROLE)
    );
    vault.updateWithdrawQueue(withdrawQueueFromRanks);

    vm.expectRevert(
      "not allocator or bot"
    );
    vault.reallocate(allocation);

    vm.stopPrank();
  }

  function testCuratorOrOwnerShouldTriggerCuratorFunctions() public {
    vm.prank(OWNER);
    vault.setCap(allMarkets[0], CAP);

    vm.prank(CURATOR_ADDR);
    vault.setCap(allMarkets[1], CAP);
  }

  function testAllocatorOrCuratorOrOwnerShouldTriggerAllocatorFunctions() public {
    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = idleParams.id();

    uint256[] memory withdrawQueueFromRanks = new uint256[](1);
    withdrawQueueFromRanks[0] = 0;

    MarketAllocation[] memory allocation;

    vm.startPrank(OWNER);
    vault.setSupplyQueue(supplyQueue);
    vault.updateWithdrawQueue(withdrawQueueFromRanks);
    vault.reallocate(allocation);

    console.log("1");
    vm.startPrank(CURATOR_ADDR);
    vault.setSupplyQueue(supplyQueue);
    vault.updateWithdrawQueue(withdrawQueueFromRanks);
    vault.reallocate(allocation);

    vm.startPrank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(supplyQueue);
    vault.updateWithdrawQueue(withdrawQueueFromRanks);
    vault.reallocate(allocation);
    vm.stopPrank();
  }
}

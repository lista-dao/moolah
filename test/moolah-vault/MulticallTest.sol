// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./helpers/IntegrationTest.sol";

contract MulticallTest is IntegrationTest {
  bytes[] internal data;

  function testMulticall() public {
    data.push(abi.encodeCall(IMoolahVault.grantRole, (CURATOR_ROLE, address(1))));
    data.push(abi.encodeCall(IMoolahVault.grantRole, (ALLOCATOR_ROLE, address(1))));

    vm.prank(OWNER);
    vault.multicall(data);

    assertTrue(vault.hasRole(CURATOR_ROLE, address(1)));
    assertTrue(vault.hasRole(ALLOCATOR_ROLE, address(1)));
  }
}

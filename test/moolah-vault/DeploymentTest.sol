// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./helpers/IntegrationTest.sol";

contract DeploymentTest is IntegrationTest {
  function testDeployMoolahVaultAddresssZero() public {
    vm.expectRevert(ErrorsLib.ZeroAddress.selector);
    new MoolahVault(address(0), address(loanToken));
  }

  function testDeployMoolahVaultNotToken(address notToken) public {
    vm.assume(address(notToken) != address(loanToken));
    vm.assume(address(notToken) != address(collateralToken));
    vm.assume(address(notToken) != address(vault));

    MoolahVault moolahVaultImpl = new MoolahVault(address(moolah), address(loanToken));
    vm.expectRevert();
    new ERC1967Proxy(
      address(moolahVaultImpl),
      abi.encodeWithSelector(
        moolahVaultImpl.initialize.selector,
        OWNER,
        OWNER,
        ConstantsLib.MIN_TIMELOCK,
        notToken,
        "Moolah Vault",
        "MMV"
      )
    );
  }

  function testDeployMoolahVault(
    address owner,
    address moolah,
    uint256 initialTimelock,
    string memory name,
    string memory symbol
  ) public {
    assumeNotZeroAddress(owner);
    assumeNotZeroAddress(moolah);
    initialTimelock = bound(initialTimelock, ConstantsLib.MIN_TIMELOCK, ConstantsLib.MAX_TIMELOCK);

    IMoolahVault newVault = createMoolahVault(owner, moolah, address(loanToken), name, symbol);

    assertTrue(newVault.hasRole(MANAGER_ROLE, owner), "owner");
    assertEq(address(newVault.MOOLAH()), moolah, "moolah");
    assertEq(newVault.asset(), address(loanToken), "asset");
    assertEq(newVault.name(), name, "name");
    assertEq(newVault.symbol(), symbol, "symbol");
    assertEq(loanToken.allowance(address(newVault), address(moolah)), type(uint256).max, "loanToken allowance");
  }
}

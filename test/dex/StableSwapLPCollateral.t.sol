import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import "../../src/dex/interfaces/IStableSwap.sol";

import { StableSwapLPCollateral } from "../../src/dex/StableSwapLPCollateral.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract StableSwapLPCollateralTest is Test {
  address moolah = address(0x100);
  address public admin = address(0x1);
  address public minter = address(0x2);
  address public user1 = address(0x3);
  address public manager = address(0x4);
  address public transferer = address(0x5);

  ERC20Mock lp = new ERC20Mock();
  StableSwapLPCollateral lpCollateral; // ss-lp collateral

  function setUp() public {
    lpCollateral = new StableSwapLPCollateral(moolah);
    ERC1967Proxy lpCollateralProxy = new ERC1967Proxy(
      address(lpCollateral),
      abi.encodeWithSelector(lpCollateral.initialize.selector, admin, address(this), lp.name(), lp.symbol())
    );
    lpCollateral = StableSwapLPCollateral(address(lpCollateralProxy));

    // Grant MANAGER role
    vm.startPrank(admin);
    lpCollateral.grantRole(lpCollateral.MANAGER(), manager);
    vm.stopPrank();
  }

  function test_transfer() public {
    vm.prank(admin);
    lpCollateral.setMinter(minter);

    vm.startPrank(minter);
    lpCollateral.mint(user1, 1000e18);
    lpCollateral.mint(moolah, 1000e18);
    vm.stopPrank();

    assertEq(lpCollateral.balanceOf(user1), 1000e18);

    vm.expectRevert("Not moolah or transferer");
    vm.prank(user1);
    lpCollateral.transfer(user1, 500e18);

    // moolah can transfer
    vm.prank(moolah);
    lpCollateral.transfer(user1, 500e18);
  }

  function test_transferFrom() public {
    vm.prank(admin);
    lpCollateral.setMinter(minter);

    vm.startPrank(minter);
    lpCollateral.mint(user1, 1000e18);
    lpCollateral.mint(moolah, 1000e18);
    vm.stopPrank();

    assertEq(lpCollateral.balanceOf(user1), 1000e18);

    vm.startPrank(user1);
    lpCollateral.approve(moolah, 500e18);
    vm.expectRevert("Not moolah or transferer");
    lpCollateral.transferFrom(user1, moolah, 500e18);
    vm.stopPrank();

    // moolah can transferFrom
    vm.startPrank(moolah);
    lpCollateral.approve(moolah, 500e18);
    lpCollateral.transferFrom(user1, moolah, 500e18);
    vm.stopPrank();
  }

  // --- setTransferer tests ---

  function test_setTransferer_byManager() public {
    vm.prank(manager);
    lpCollateral.setTransferer(transferer, true);

    assertTrue(lpCollateral.hasRole(lpCollateral.TRANSFERER(), transferer));
  }

  function test_setTransferer_revoke() public {
    vm.startPrank(manager);
    lpCollateral.setTransferer(transferer, true);
    lpCollateral.setTransferer(transferer, false);
    vm.stopPrank();

    assertFalse(lpCollateral.hasRole(lpCollateral.TRANSFERER(), transferer));
  }

  function test_setTransferer_revertIfNotManager() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, lpCollateral.MANAGER())
    );
    vm.prank(user1);
    lpCollateral.setTransferer(transferer, true);
  }

  function test_setTransferer_revertIfZeroAddress() public {
    vm.expectRevert("Zero address");
    vm.prank(manager);
    lpCollateral.setTransferer(address(0), true);
  }

  // --- TRANSFERER role transfer/transferFrom tests ---

  function test_transfererCanTransfer() public {
    vm.prank(manager);
    lpCollateral.setTransferer(transferer, true);

    vm.startPrank(admin);
    lpCollateral.setMinter(minter);
    vm.stopPrank();

    vm.prank(minter);
    lpCollateral.mint(transferer, 1000e18);

    vm.prank(transferer);
    lpCollateral.transfer(user1, 500e18);

    assertEq(lpCollateral.balanceOf(user1), 500e18);
    assertEq(lpCollateral.balanceOf(transferer), 500e18);
  }

  function test_transfererCanTransferFrom() public {
    vm.prank(manager);
    lpCollateral.setTransferer(transferer, true);

    vm.startPrank(admin);
    lpCollateral.setMinter(minter);
    vm.stopPrank();

    vm.prank(minter);
    lpCollateral.mint(user1, 1000e18);

    vm.prank(user1);
    lpCollateral.approve(transferer, 500e18);

    vm.prank(transferer);
    lpCollateral.transferFrom(user1, transferer, 500e18);

    assertEq(lpCollateral.balanceOf(transferer), 500e18);
    assertEq(lpCollateral.balanceOf(user1), 500e18);
  }

  function test_revokedTransfererCannotTransfer() public {
    vm.startPrank(manager);
    lpCollateral.setTransferer(transferer, true);
    lpCollateral.setTransferer(transferer, false);
    vm.stopPrank();

    vm.startPrank(admin);
    lpCollateral.setMinter(minter);
    vm.stopPrank();

    vm.prank(minter);
    lpCollateral.mint(transferer, 1000e18);

    vm.expectRevert("Not moolah or transferer");
    vm.prank(transferer);
    lpCollateral.transfer(user1, 500e18);
  }

  // --- MANAGER role grant/revoke tests ---

  function test_grantManagerRole() public {
    address newManager = address(0x6);
    vm.startPrank(admin);
    lpCollateral.grantRole(lpCollateral.MANAGER(), newManager);
    vm.stopPrank();

    assertTrue(lpCollateral.hasRole(lpCollateral.MANAGER(), newManager));
  }

  function test_revokeManagerRole() public {
    vm.startPrank(admin);
    lpCollateral.revokeRole(lpCollateral.MANAGER(), manager);
    vm.stopPrank();

    assertFalse(lpCollateral.hasRole(lpCollateral.MANAGER(), manager));
  }

  function test_grantManagerRole_revertIfNotAdmin() public {
    bytes32 managerRole = lpCollateral.MANAGER();
    bytes32 adminRole = lpCollateral.DEFAULT_ADMIN_ROLE();
    vm.startPrank(user1);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, adminRole));
    lpCollateral.grantRole(managerRole, user1);
    vm.stopPrank();
  }

  function test_revokedManagerCannotSetTransferer() public {
    vm.startPrank(admin);
    lpCollateral.revokeRole(lpCollateral.MANAGER(), manager);
    vm.stopPrank();

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, lpCollateral.MANAGER())
    );
    vm.prank(manager);
    lpCollateral.setTransferer(transferer, true);
  }
}

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import "../../src/dex/interfaces/IStableSwap.sol";

import { StableSwapLPCollateral } from "../../src/dex/StableSwapLPCollateral.sol";

contract StableSwapLPCollateralTest is Test {
  address moolah = address(0x100);
  address public admin = address(0x1);
  address public minter = address(0x2);
  address public user1 = address(0x3);

  ERC20Mock lp = new ERC20Mock();
  StableSwapLPCollateral lpCollateral; // ss-lp collateral

  function setUp() public {
    lpCollateral = new StableSwapLPCollateral(moolah);
    ERC1967Proxy lpCollateralProxy = new ERC1967Proxy(
      address(lpCollateral),
      abi.encodeWithSelector(lpCollateral.initialize.selector, admin, address(this), lp.name(), lp.symbol())
    );
    lpCollateral = StableSwapLPCollateral(address(lpCollateralProxy));
  }

  function test_transfer() public {
    vm.prank(admin);
    lpCollateral.setMinter(minter);

    vm.startPrank(minter);
    lpCollateral.mint(user1, 1000e18);
    lpCollateral.mint(moolah, 1000e18);
    vm.stopPrank();

    assertEq(lpCollateral.balanceOf(user1), 1000e18);

    vm.expectRevert("Not moolah");
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
    vm.expectRevert("Not moolah");
    lpCollateral.transferFrom(user1, moolah, 500e18);
    vm.stopPrank();

    // moolah can transferFrom
    vm.startPrank(moolah);
    lpCollateral.approve(moolah, 500e18);
    lpCollateral.transferFrom(user1, moolah, 500e18);
    vm.stopPrank();
  }
}

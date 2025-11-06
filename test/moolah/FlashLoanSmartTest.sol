pragma solidity 0.8.28;

import "../../src/moolah/FlashLoanSmart.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

contract FlashLoanSmartTest is Test {
  address admin = address(0x1A11AA);
  address moolah = address(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address USDT = address(0x55d398326f99059fF775485246999027B3197955);
  address lisUSD = address(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);

  address slisBNB = address(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B);
  address wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

  uint256 mainnet;

  FlashLoanSmart callbackLocal;

  function setUp() public {
    deal(admin, 1 ether);
    mainnet = vm.createSelectFork("https://bsc-dataseed.binance.org");

    TransparentUpgradeableProxy providerProxy = new TransparentUpgradeableProxy(
      address(new FlashLoanSmart()),
      admin,
      abi.encodeWithSignature("initialize(address)", admin)
    );
    callbackLocal = FlashLoanSmart(payable(address(providerProxy)));

    console.log("FlashLoanSmart proxy address: %s", address(callbackLocal));
  }

  function test_setUp() public {
    assertEq(true, callbackLocal.hasRole(keccak256("MANAGER"), admin));
    assertEq(moolah, callbackLocal.moolahAddress());
  }

  function test_withdraw() public {
    deal(address(slisBNB), address(callbackLocal), 1_000 ether);
    vm.startPrank(admin);
    callbackLocal.withdrawERC20(address(slisBNB), 1_000 ether);
    vm.stopPrank();

    assertEq(1_000 ether, IERC20(address(slisBNB)).balanceOf(admin));
  }

  function test_callMoolahFlashSmart() public {
    bytes
      memory data = hex"04e45aaf000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c000000000000000000000000b0b84d294e0c75a6abe60171b70edeb2efd14a1b00000000000000000000000000000000000000000000000000000000000001f40000000000000000000000002e234dae75c793f67a35089c9d99245e1c58470b000000000000000000000000000000000000000000000002ccea663b29f94000000000000000000000000000000000000000000000000002b3b49fa1280c3f440000000000000000000000000000000000000000000000000000000000000000";

    vm.startPrank(admin);
    callbackLocal.callMoolahFlashSmart(
      slisBNB,
      50 ether,
      0.01 ether,
      wbnb,
      address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4),
      data
    );
    vm.stopPrank();
  }
}

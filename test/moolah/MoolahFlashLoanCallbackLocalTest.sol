pragma solidity 0.8.28;

import "../../src/moolah/MoolahFlashLoanCallbackLocal.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

contract MoolahFlashLoanCallbackLocalTest is Test {
  address admin = address(0x1A11AA);
  address moolah = address(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address USDT = address(0x55d398326f99059fF775485246999027B3197955);
  address lisUSD = address(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);

  uint256 mainnet;

  MoolahFlashLoanCallbackLocal callbackLocal;

  function setUp() public {
    deal(admin, 1 ether);
    mainnet = vm.createSelectFork("https://bsc-dataseed.binance.org");

    TransparentUpgradeableProxy providerProxy = new TransparentUpgradeableProxy(
      address(new MoolahFlashLoanCallbackLocal()),
      admin,
      abi.encodeWithSignature("initialize(address)", admin)
    );
    callbackLocal = MoolahFlashLoanCallbackLocal(address(providerProxy));
  }

  function test_setUp() public {
    assertEq(true, callbackLocal.hasRole(keccak256("MANAGER"), admin));
    assertEq(moolah, callbackLocal.moolahAddress());
  }

  function test_remote_config() public {
    MoolahFlashLoanCallbackLocal remote = MoolahFlashLoanCallbackLocal(
      address(0x917cdD6420248509361fC3b8738e52d85A25D272)
    );
    assertEq(false, remote.hasRole(keccak256("MANAGER"), admin));
    assertEq(true, remote.hasRole(keccak256("MANAGER"), address(0x32004FBCa565b4c16A12a0FAEdc3b8d2F395cb31)));

    deal(USDT, address(remote), 500 ether);
    vm.prank(address(0x32004FBCa565b4c16A12a0FAEdc3b8d2F395cb31));
    remote.withdrawERC20(USDT, 500 ether);

    vm.prank(admin);
    remote.withdrawERC20(USDT, 500 ether);

    vm.prank(address(0x32004FBCa565b4c16A12a0FAEdc3b8d2F395cb31));
    remote.withdrawERC20(USDT, 500 ether);
  }

  function test_withdraw() public {
    deal(address(0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d), address(callbackLocal), 1_000 ether);
    vm.startPrank(admin);
    callbackLocal.withdrawERC20(address(0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d), 1_000 ether);
    vm.stopPrank();

    assertEq(1_000 ether, IERC20(address(0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d)).balanceOf(admin));
  }

  function test_callMoolahFlash() public {
    bytes
      memory data = hex"b455423100000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000a968163f0a57b400000000000000000000000000000000000000000000000000a87389da03942aa5c4d0000000000000000000000002e234dae75c793f67a35089c9d99245e1c58470b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000782b6d8c4551b9760e74c0545a9bcd90bdc41e500000000000000000000000055d398326f99059ff775485246999027b319795500000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    deal(USDT, address(callbackLocal), 1_000 ether);
    console.log("Moolah USDT before flashloan:", IERC20(USDT).balanceOf(address(callbackLocal)));

    vm.startPrank(admin);
    callbackLocal.callMoolahFlash(
      USDT,
      50_000 ether,
      1 ether,
      lisUSD,
      address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4),
      data
    );
    vm.stopPrank();

    console.log("Moolah USDT after flashloan:", IERC20(USDT).balanceOf(address(callbackLocal)));
  }

  function test_callFlashLiquidate() public {
    vm.prank(address(0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04));
    IPublicLiquidator(address(0x882475d622c687b079f149B69a15683FCbeCC6D9)).setMarketWhitelist(
      0xdf9ad2d18a115cc0ee9239a174a4f0d1b22d7d1393ec71e37638f8f7be68f78c,
      true
    );
    bytes
      memory data = hex"b858183f00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000080000000000000000000000000882475d622c687b079f149b69a15683fcbecc6d9000000000000000000000000000000000000000000000cb49b44ba602d80000000000000000000000000000000000000000000000000001b7df566bde33d63180000000000000000000000000000000000000000000000000000000000000042f307910a4c7bbc79691fd374889b36d8531b08e300271055d398326f99059ff775485246999027b31979550000648d0d000ee44948fc98c9b98a4fa4921476f08b0d000000000000000000000000000000000000000000000000000000000000";

    console.log(
      "ANKR before: ",
      IERC20(address(0xf307910A4c7bbc79691fD374889b36d8531B08e3)).balanceOf(address(callbackLocal))
    );
    console.log(
      "USD1 before: ",
      IERC20(address(0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d)).balanceOf(address(callbackLocal))
    );

    vm.startPrank(admin);
    callbackLocal.callFlashLiquidate(
      0xdf9ad2d18a115cc0ee9239a174a4f0d1b22d7d1393ec71e37638f8f7be68f78c,
      address(0x146eE71e057e6B10eFB93AEdf631Fde6CbAED5E2),
      60_000 ether,
      address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4),
      data
    );
    vm.stopPrank();

    console.log(
      "ANKR after: ",
      IERC20(address(0xf307910A4c7bbc79691fD374889b36d8531B08e3)).balanceOf(address(callbackLocal))
    );
    console.log(
      "USD1 after: ",
      IERC20(address(0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d)).balanceOf(address(callbackLocal))
    );
  }
}

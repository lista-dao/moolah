pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SlisBNBxMinter } from "src/utils/SlisBNBxMinter.sol";

contract StableSwapLPCollateralDeploy is Script {
  //  address slisBNBx_test = 0x3dC5a40119B85d5f2b06eEC86a6d36852bd9aB52;
  //  address slisBnbModule_test = 0x0612c940460D68C16aA213315E32Fba579beD6A6;
  //  address smartLpModule_test = 0x3953B325b5aD068E74D1fc58fc66CE4440F1E2FF;

  address slisBnbx = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
  address smartLpModule = 0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE;
  address slisBnbModule = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    SlisBNBxMinter.ModuleConfig[] memory moduleConfigs = new SlisBNBxMinter.ModuleConfig[](2);
    moduleConfigs[0] = SlisBNBxMinter.ModuleConfig({
      discount: 0,
      feeRate: 3e4, // 3%
      moduleAddress: slisBnbModule
    });
    moduleConfigs[1] = SlisBNBxMinter.ModuleConfig({
      discount: 2e3, // 0.2%
      feeRate: 18367, // 1.8%/0.998 = 18e3/0.98 = approx 1.8367% = 18367
      moduleAddress: smartLpModule
    });

    address[] memory modules = new address[](2);
    modules[0] = slisBnbModule;
    modules[1] = smartLpModule;

    SlisBNBxMinter impl = new SlisBNBxMinter(slisBnbx);
    console.log("SlisBNBxMinter implementation: ", address(impl));

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(SlisBNBxMinter.initialize.selector, deployer, deployer, modules, moduleConfigs)
    );
    console.log("SlisBNBxMinter proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

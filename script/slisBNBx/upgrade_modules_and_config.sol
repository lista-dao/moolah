pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SlisBNBxMinter } from "src/utils/SlisBNBxMinter.sol";
import { SlisBNBProvider } from "src/provider/SlisBNBProvider.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

interface IUpgrade {
  function upgradeToAndCall(address newImplementation, bytes calldata data) external;
}

contract StableSwapLPCollateralDeploy is Script {
  address slisBNBx_test = 0x3dC5a40119B85d5f2b06eEC86a6d36852bd9aB52;
  address slisBnbModule_test = 0x0612c940460D68C16aA213315E32Fba579beD6A6;
  address smartLpModule_test = 0x3953B325b5aD068E74D1fc58fc66CE4440F1E2FF;
  address minter_test = 0x2431C98A90624808042106d9822b3397e6351B11;

  address slisBNB_test = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address stakeManager_test = 0xc695F964011a5a1024931E2AF0116afBaC41B31B;
  address moolah_test = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address lpCollateral_test = 0x7c2b49bbF5fd96913513c373c5a76E7356D470e1;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // upgrade SlisBNBProvider
    address newImlp = address(
      new SlisBNBProvider(address(moolah_test), slisBNB_test, stakeManager_test, slisBNBx_test)
    );
    IUpgrade(slisBnbModule_test).upgradeToAndCall(newImlp, "");
    console.log("SlisBNBProvider upgraded");

    // upgrade SmartProvider
    newImlp = address(new SmartProvider(moolah_test, lpCollateral_test));
    IUpgrade(smartLpModule_test).upgradeToAndCall(newImlp, "");
    console.log("SmartProvider upgraded");

    vm.stopBroadcast();
  }
}

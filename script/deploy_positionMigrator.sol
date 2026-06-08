pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PositionMigrator } from "../src/utils/PositionMigrator.sol";

contract PositionMigratorDeploy is Script {
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy PositionMigrator implementation
    PositionMigrator impl = new PositionMigrator();
    console.log("PositionMigrator implementation: ", address(impl));

    // BNB and slisBNB are added automatically in initialize()
    address[] memory supportedCollaterals = new address[](2);
    supportedCollaterals[0] = wBETH;
    supportedCollaterals[1] = BTCB;

    // Deploy PositionMigrator proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, supportedCollaterals)
    );
    console.log("PositionMigrator proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

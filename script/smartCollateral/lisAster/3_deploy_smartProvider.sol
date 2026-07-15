pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

import "./LisAsterAddress.sol";

// Step 3: deploy the SmartProvider (which also serves as the market oracle) and
//         hand the collateral's minter role to it.
//
// Requires DEX_LISASTER_ASTER and COLLATERAL_LISASTER_ASTER set in LisAsterAddress.sol.
//
// forge script script/smartCollateral/lisAster/3_deploy_smartProvider.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract DeployLisAsterAsterSmartProvider is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    address smartLp = COLLATERAL_LISASTER_ASTER;
    address dex = DEX_LISASTER_ASTER;
    require(smartLp != address(0), "set COLLATERAL_LISASTER_ASTER first");
    require(dex != address(0), "set DEX_LISASTER_ASTER first");

    vm.startBroadcast(deployerPrivateKey);

    SmartProvider impl = new SmartProvider(MOOLAH, smartLp);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, dex, SS_INFO, RESILIENT_ORACLE)
    );

    console.log("SmartProvider deployed at: ", address(proxy));

    // set minter to smart provider
    StableSwapLPCollateral(smartLp).setMinter(address(proxy));
    console.log("Minter set to SmartProvider");

    vm.stopBroadcast();

    console.log("NEXT: set SMART_PROVIDER_LISASTER_ASTER in LisAsterAddress.sol");
  }
}

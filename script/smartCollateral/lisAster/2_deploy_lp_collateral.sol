pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";

import "./LisAsterAddress.sol";

// Step 2: deploy the SmartLP collateral token used as Moolah collateral.
//
// forge script script/smartCollateral/lisAster/2_deploy_lp_collateral.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract DeployLisAsterAsterCollateral is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    string memory name = "lisAster & ASTER-SmartLP";

    vm.startBroadcast(deployerPrivateKey);

    StableSwapLPCollateral impl = new StableSwapLPCollateral(MOOLAH);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer, // admin
        deployer, // minter (reassigned to SmartProvider in step 3)
        name,
        name
      )
    );

    console.log("StableSwapLPCollateral proxy: ", address(proxy));

    vm.stopBroadcast();

    console.log("NEXT: set COLLATERAL_LISASTER_ASTER in LisAsterAddress.sol");
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OracleAdaptor } from "../src/oracle/OracleAdaptor.sol";

contract OracleAdaptorDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    OracleAdaptor impl = new OracleAdaptor();
    console.log("OracleAdaptor implementation: ", address(impl));
    address[] memory srcAsset = new address[](1);
    srcAsset[0] = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e; // mainnnet pt-clisBNB-25apr
    address[] memory targetAsset = new address[](1);
    targetAsset[0] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // mainnet WBNB

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, srcAsset, targetAsset)
    );
    console.log("OracleAdaptor proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

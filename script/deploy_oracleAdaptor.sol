pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OracleAdaptor } from "../src/oracle/OracleAdaptor.sol";

contract OracleAdaptorDeploy is Script {
  address oracle = 0x79e9675cDe605Ef9965AbCE185C5FD08d0DE16B1;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    OracleAdaptor impl = new OracleAdaptor();
    console.log("OracleAdaptor implementation: ", address(impl));
    address[] memory srcAsset = new address[](1);
    srcAsset[0] = 0xA35743F08E958a5e9Cf40F9AF23dcC5DED1faDE0; // testnet pt-clisBNB-25apr
    address[] memory targetAsset = new address[](1);
    targetAsset[0] = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // testnet WBNB

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, srcAsset, targetAsset)
    );
    console.log("OracleAdaptor proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

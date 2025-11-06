pragma solidity 0.8.28;

import "../src/moolah/MoolahFlashLoanCallbackLocal.sol";

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Moolah } from "moolah/Moolah.sol";

contract Moolah2Deploy is Script {
  uint256 private constant MIN_LOAN_VALUE = 15 * 1e8;

  /**
   * forge script script/deploy_moolah2.sol:Moolah2Deploy --rpc-url https://bsc-testnet.nodereal.io/v1/54418b8a87df4f9fa7cf1ca161cdad9f --etherscan-api-key V57EIV2C76VR6SW8AAY6NJFSBS1U4CQPHT --broadcast --verify -vvv --via-ir
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy Moolah implementation
    MoolahFlashLoanCallbackLocal impl = new MoolahFlashLoanCallbackLocal();
    console.log("MoolahFlashLoanCallbackLocal implementation: ", address(impl));

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer));
    console.log("MoolahFlashLoanCallbackLocal proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

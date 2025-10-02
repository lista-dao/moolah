pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LendingFeeRecipient } from "revenue/LendingFeeRecipient.sol";

contract LendingFeeRecipientDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy LendingFeeRecipient implementation
    LendingFeeRecipient impl = new LendingFeeRecipient();
    console.log("LendingFeeRecipient implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TimeLock } from "timelock/TimeLock.sol";

contract TimeLockDeploy is Script {
  // todo
  address proposer = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address executor = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address canceller = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address admin = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy TimeLock
    address[] memory proposers = new address[](1);
    proposers[0] = proposer;
    address[] memory executors = new address[](1);
    executors[0] = executor;
    TimeLock timeLock = new TimeLock(proposers, executors, deployer);
    console.log("TimeLock deploy to: ", address(timeLock));

    // setup roles
    timeLock.grantRole(timeLock.CANCELLER_ROLE(), canceller);
    timeLock.grantRole(timeLock.DEFAULT_ADMIN_ROLE(), admin);
    timeLock.revokeRole(timeLock.DEFAULT_ADMIN_ROLE(), deployer);

    console.log("setup role done!");
    vm.stopBroadcast();
  }
}

pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TimeLock } from "timelock/TimeLock.sol";

contract TimeLockDeploy is Script {
  address proposer = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address executor = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address canceller = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  uint256 minDelay = 1 days;

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
    TimeLock timeLock = new TimeLock(proposers, executors, deployer, minDelay);
    console.log("TimeLock deploy to: ", address(timeLock));

    // setup roles
    timeLock.grantRole(timeLock.CANCELLER_ROLE(), canceller);
    timeLock.grantRole(timeLock.DEFAULT_ADMIN_ROLE(), address(timeLock));
    timeLock.revokeRole(timeLock.DEFAULT_ADMIN_ROLE(), deployer);

    console.log("setup role done!");
    vm.stopBroadcast();
  }
}

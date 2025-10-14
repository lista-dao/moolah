pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TimeLock } from "timelock/TimeLock.sol";

contract TimeLockDeploy is Script {
  address managerProposer = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address managerExecutor = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address adminProposer = 0x08aE09467ff962aF105c23775B9Bc8EAa175D27F;
  address adminExecutor = 0x08aE09467ff962aF105c23775B9Bc8EAa175D27F;
  address canceller = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  uint256 minDelay = 1 days;

  function run() public {
    address manager = deployTimeLock(managerProposer, managerExecutor, canceller, minDelay);
    address admin = deployTimeLock(adminProposer, adminExecutor, canceller, minDelay);
    console.log("manager TimeLock: ", manager);
    console.log("admin TimeLock: ", admin);
  }

  function deployTimeLock(
    address proposer,
    address executor,
    address canceller,
    uint256 minDelay
  ) public returns (address) {
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

    console.log("setup role done!");
    vm.stopBroadcast();

    return address(timeLock);
  }
}

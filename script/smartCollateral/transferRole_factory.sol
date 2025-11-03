pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapPoolInfo } from "src/dex/StableSwapPoolInfo.sol";
import "./SCAddress.sol";

contract TransferRole is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role
  bytes32 public constant DEPLOYER = keccak256("DEPLOYER");

  address deployer2 = 0x89e68b97466c65e215C0B13de256188867f358Ae;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapPoolInfo poolInfo = StableSwapPoolInfo(SS_INFO);
    poolInfo.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    poolInfo.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for StableSwapPoolInfo: ", SS_INFO);

    StableSwapFactory factory = StableSwapFactory(SS_FACTORY);
    factory.grantRole(DEPLOYER, deployer2);
    factory.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    factory.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for StableSwapFactory: ", SS_FACTORY);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

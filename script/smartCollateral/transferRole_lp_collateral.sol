pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import "./SCAddress.sol";

contract TransferRole is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapLPCollateral collateral1 = StableSwapLPCollateral(COLLATERAL_SOLVBTC_BTCB);
    StableSwapLPCollateral collateral2 = StableSwapLPCollateral(COLLATERAL_SLISBNB_BNB);

    collateral1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    collateral1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for COLLATERAL_SOLVBTC_BTCB: ", COLLATERAL_SOLVBTC_BTCB);

    collateral2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    collateral2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for COLLATERAL_SLISBNB_BNB: ", COLLATERAL_SLISBNB_BNB);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

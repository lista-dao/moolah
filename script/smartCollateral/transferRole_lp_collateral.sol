pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import "./SCAddress.sol";

// Step 4c — hand off StableSwapLPCollateral DEFAULT_ADMIN -> ADMIN, revoke deployer.
// Fill COLLATERAL_USD1_USDT / COLLATERAL_LISUSD_USDT in SCAddress first.
contract TransferRole is DeployBase {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapLPCollateral collateral1 = StableSwapLPCollateral(COLLATERAL_USD1_USDT);
    StableSwapLPCollateral collateral2 = StableSwapLPCollateral(COLLATERAL_LISUSD_USDT);

    collateral1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    collateral1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for COLLATERAL_USD1_USDT: ", COLLATERAL_USD1_USDT);

    collateral2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    collateral2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for COLLATERAL_LISUSD_USDT: ", COLLATERAL_LISUSD_USDT);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

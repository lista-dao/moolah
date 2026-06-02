pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StableSwapPool } from "src/dex/StableSwapPool.sol";
import "./SCAddress.sol";

// Step 4a — hand off StableSwapPool roles (DEFAULT_ADMIN+MANAGER -> ADMIN, PAUSER -> PAUSER), revoke deployer.
// Fill DEX_USD1_USDT / DEX_LISUSD_USDT in SCAddress first.
contract TransferRole is DeployBase {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapPool pool1 = StableSwapPool(DEX_USD1_USDT);
    StableSwapPool pool2 = StableSwapPool(DEX_LISUSD_USDT);

    pool1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    pool1.grantRole(MANAGER, MANAGER_ADDR);
    pool1.grantRole(PAUSER, PAUSER_ADDR);
    pool1.revokeRole(PAUSER, deployer);
    pool1.revokeRole(MANAGER, deployer);
    pool1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_USD1_USDT: ", DEX_USD1_USDT);

    pool2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    pool2.grantRole(MANAGER, MANAGER_ADDR);
    pool2.grantRole(PAUSER, PAUSER_ADDR);
    pool2.revokeRole(PAUSER, deployer);
    pool2.revokeRole(MANAGER, deployer);
    pool2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_LISUSD_USDT: ", DEX_LISUSD_USDT);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

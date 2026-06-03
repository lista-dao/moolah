pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";
import "./SCAddress.sol";

// Step 4b — hand off StableSwapLP DEFAULT_ADMIN -> ADMIN, revoke deployer.
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
    StableSwapLP lp1 = StableSwapLP(pool1.token());

    StableSwapPool pool2 = StableSwapPool(DEX_LISUSD_USDT);
    StableSwapLP lp2 = StableSwapLP(pool2.token());

    lp1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    lp1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_USD1_USDT LP: ", pool1.token());

    lp2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    lp2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_LISUSD_USDT LP: ", pool2.token());

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

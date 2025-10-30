pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { StableSwapPool } from "src/dex/StableSwapPool.sol";
import "./SCAddress.sol";

contract TransferRole is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    StableSwapPool pool1 = StableSwapPool(DEX_BTCB_SOLVBTC);
    StableSwapPool pool2 = StableSwapPool(DEX_BNB_SLISBNB);

    pool1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    pool1.grantRole(MANAGER, ADMIN_ADDR);
    pool1.grantRole(PAUSER, PAUSER_ADDR);

    pool1.revokeRole(PAUSER, deployer);
    pool1.revokeRole(MANAGER, deployer);
    pool1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    console.log("Transferred role for DEX_BTCB_SOLVBTC: ", DEX_BTCB_SOLVBTC);

    pool2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    pool2.grantRole(MANAGER, ADMIN_ADDR);
    pool2.grantRole(PAUSER, PAUSER_ADDR);
    pool2.revokeRole(PAUSER, deployer);
    pool2.revokeRole(MANAGER, deployer);
    pool2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_BNB_SLISBNB: ", DEX_BNB_SLISBNB);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

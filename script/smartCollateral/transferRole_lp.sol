pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { StableSwapLP } from "src/dex/StableSwapLP.sol";
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
    StableSwapLP lp1 = StableSwapLP(pool1.token());

    StableSwapPool pool2 = StableSwapPool(DEX_BNB_SLISBNB);
    StableSwapLP lp2 = StableSwapLP(pool2.token());

    lp1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    lp1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_BTCB_SOLVBTC: ", pool1.token());

    lp2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    lp2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for DEX_BNB_SLISBNB: ", pool2.token());

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

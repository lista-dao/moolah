pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { SmartProvider } from "src/provider/SmartProvider.sol";
import "./SCAddress.sol";

// Step 4d — hand off SmartProvider DEFAULT_ADMIN -> ADMIN, revoke deployer.
// Fill SMART_PROVIDER_USD1_USDT / SMART_PROVIDER_LISUSD_USDT in SCAddress first.
contract TransferRole is DeployBase {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    SmartProvider provider1 = SmartProvider(payable(SMART_PROVIDER_USD1_USDT));
    SmartProvider provider2 = SmartProvider(payable(SMART_PROVIDER_LISUSD_USDT));

    provider1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    provider1.grantRole(MANAGER, MANAGER_ADDR);
    provider1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for SMART_PROVIDER_USD1_USDT: ", SMART_PROVIDER_USD1_USDT);

    provider2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDR);
    provider2.grantRole(MANAGER, MANAGER_ADDR);
    provider2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for SMART_PROVIDER_LISUSD_USDT: ", SMART_PROVIDER_LISUSD_USDT);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

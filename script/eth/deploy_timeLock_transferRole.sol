pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TimeLock } from "timelock/TimeLock.sol";

contract TimeLockTransferRoleDeploy is DeployBase {
  TimeLock adminTimeLock = TimeLock(payable(0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61));
  TimeLock managerTimeLock = TimeLock(payable(0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA));
  address canceller = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    adminTimeLock.grantRole(adminTimeLock.CANCELLER_ROLE(), canceller);
    managerTimeLock.grantRole(managerTimeLock.CANCELLER_ROLE(), canceller);

    adminTimeLock.revokeRole(adminTimeLock.DEFAULT_ADMIN_ROLE(), deployer);
    managerTimeLock.revokeRole(managerTimeLock.DEFAULT_ADMIN_ROLE(), deployer);

    console.log("setup role done!");
    vm.stopBroadcast();
  }
}

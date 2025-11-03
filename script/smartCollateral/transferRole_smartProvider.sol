pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { SmartProvider } from "src/provider/SmartProvider.sol";
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

    SmartProvider provider1 = SmartProvider(payable(SMART_PROVIDER_BTCB_SOLVBTC));
    SmartProvider provider2 = SmartProvider(payable(SMART_PROVIDER_BNB_SLISBNB));

    provider1.grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
    provider1.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for SMART_PROVIDER_BTCB_SOLVBTC: ", SMART_PROVIDER_BTCB_SOLVBTC);

    provider2.grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
    provider2.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    console.log("Transferred role for SMART_PROVIDER_BNB_SLISBNB: ", SMART_PROVIDER_BNB_SLISBNB);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}

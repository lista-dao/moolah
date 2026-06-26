pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

/// @notice Step 6: Transfer WETH vault roles to TimeLock
contract MoolahVaultTransferRoleWETHDeploy is DeployBase {
  MoolahVault wethVault;

  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // Admin TimeLock
  address manager = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA; // Manager TimeLock
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address curator = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function run() public {
    wethVault = MoolahVault(vm.envAddress("WETH_VAULT"));
    require(address(wethVault) != address(0), "WETH_VAULT env not set");

    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    wethVault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    wethVault.grantRole(MANAGER, manager);
    wethVault.grantRole(ALLOCATOR, allocator);
    wethVault.grantRole(CURATOR, curator);

    wethVault.revokeRole(CURATOR, deployer);
    wethVault.revokeRole(ALLOCATOR, deployer);
    wethVault.revokeRole(MANAGER, deployer);
    wethVault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("WETH vault role transfer done!");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { DeployBase } from "../DeployBase.sol";
import { BrokerInterestLockBuffer } from "../../src/utils/BrokerInterestLockBuffer.sol";

/// @notice Deploys BrokerInterestLockBuffer (audit #08) for a single MoolahVault.
///
/// ATOMICITY — proxy deploy + initialize MUST happen in the SAME transaction.
/// `new ERC1967Proxy(impl, initData)` is atomic by construction: the proxy's constructor
/// sets the impl slot AND delegatecalls `initialize(...)` inside the same CREATE, so the
/// proxy never exists in an uninitialized state. Do NOT split the deploy and the init
/// into two transactions — that opens a front-run window where someone else can call
/// `initialize` first and seize admin.
///
/// Env vars:
///   TIMELOCK              - DEFAULT_ADMIN_ROLE recipient (must be a TimeLock)
///   MANAGER               - MANAGER role recipient (config / setDuration)
///   VAULT                 - the bound MoolahVault (asset is read from the vault)
///   RELAYERS              - comma-separated list of relayer addresses to grant RELAYER role
///   LOCK_DURATION_SECONDS - initial unlock window in seconds (default 21600 = 6h)
///
/// Rollout reminder (must be ordered):
///   1. (this script) deploy buffer + grant RELAYER + hand off admin/manager
///   2. upgrade BrokerInterestRelayer / CreditBrokerInterestRelayer to the buffer-aware impl
///   3. SEED THE VAULT (audit M-06) — governance deposits a small never-withdrawn balance into
///      the vault and assigns the shares to TIMELOCK. Required to prevent two failure modes if
///      every LP ever redeems while currentLocked() > 0:
///        - orphaned Moolah supply shares (no claimer for the locked reward), and
///        - the inflation-attack window where totalAssets > 0 while totalSupply == 0.
///   4. vault.setLockBuffer(<bufferProxy>)  -- only after steps 2 and 3 land
contract DeployBrokerInterestLockBuffer is DeployBase {
  address timelock;
  address manager;
  address vault;
  address[] relayers;
  uint64 duration;

  function setUp() public {
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
    vault = vm.envAddress("VAULT");
    relayers = vm.envAddress("RELAYERS", ",");
    duration = uint64(vm.envOr("LOCK_DURATION_SECONDS", uint256(6 hours)));
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    address asset = IERC4626(vault).asset();

    console.log("Deployer:               ", deployer);
    console.log("Vault:                  ", vault);
    console.log("Asset (read from vault):", asset);
    console.log("Duration (sec):         ", uint256(duration));
    console.log("Relayer count:          ", relayers.length);
    console.log("Manager:                ", manager);
    console.log("Timelock (admin):       ", timelock);

    vm.startBroadcast(deployerPrivateKey);

    // 1. Deploy the implementation. Constructor calls `_disableInitializers()`.
    BrokerInterestLockBuffer impl = new BrokerInterestLockBuffer();
    console.log("Buffer impl:            ", address(impl));

    // 2. Deploy proxy AND initialize in a SINGLE CREATE — atomic by construction.
    //    Roles are temporarily granted to `deployer` so the rest of this broadcast can
    //    grant RELAYER / hand off MANAGER / DEFAULT_ADMIN_ROLE without a second tx.
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        BrokerInterestLockBuffer.initialize.selector,
        deployer, // admin (temp)
        deployer, // manager (temp)
        vault,
        asset,
        duration
      )
    );
    BrokerInterestLockBuffer buffer = BrokerInterestLockBuffer(address(proxy));
    console.log("Buffer proxy:           ", address(proxy));

    // 3. Grant RELAYER to each configured relayer.
    bytes32 RELAYER = keccak256("RELAYER");
    for (uint256 i = 0; i < relayers.length; ++i) {
      buffer.grantRole(RELAYER, relayers[i]);
      console.log("Granted RELAYER to:     ", relayers[i]);
    }

    // 4. Hand off MANAGER and DEFAULT_ADMIN_ROLE to their final holders.
    bytes32 MANAGER = keccak256("MANAGER");
    bytes32 DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    buffer.grantRole(MANAGER, manager);
    buffer.grantRole(DEFAULT_ADMIN_ROLE, timelock);

    // 5. Revoke the deployer's temporary roles in the same broadcast so the deployer EOA cannot
    //    upgrade the buffer impl or reset the unlock clock after deploy. Order matters: revoke
    //    MANAGER first (still callable by ourselves while we hold DEFAULT_ADMIN_ROLE), then drop
    //    DEFAULT_ADMIN_ROLE last.
    buffer.revokeRole(MANAGER, deployer);
    buffer.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();
  }
}

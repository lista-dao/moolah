// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IMoolahVault } from "./interfaces/IMoolahVault.sol";
import { IMoolahVaultFactory } from "./interfaces/IMoolahVaultFactory.sol";
import { TimeLock } from "timelock/TimeLock.sol";

import { EventsLib } from "./libraries/EventsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";

/// @title MoolahVaultFactory
/// @notice This contract allows to create MoolahVault, and to index them easily.
contract MoolahVaultFactory is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IMoolahVaultFactory {
  /* IMMUTABLES */

  /// @inheritdoc IMoolahVaultFactory
  address public immutable MOOLAH;

  address public constant MOOLAH_VAULT_IMPL_18 = 0xFAeccDB40688d3674925B48d1B913D0397785f4C;

  address public vaultAdmin;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant CURATOR = keccak256("CURATOR"); // curator role
  bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
  bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

  /* STORAGE */

  /// @inheritdoc IMoolahVaultFactory
  mapping(address => bool) public isMoolahVault;

  /// CONSTRUCTOR
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    if (moolah == address(0)) revert ErrorsLib.ZeroAddress();

    MOOLAH = moolah;

    _disableInitializers();
  }

  /// @dev Initializes the contract.
  /// @param admin The new admin of the contract.
  /// @param _vaultAdmin The admin of vaults created by this contract.
  function initialize(
    address admin,
    address _vaultAdmin
  ) public initializer {
    if (admin == address(0)) revert ErrorsLib.ZeroAddress();
    if (_vaultAdmin == address(0)) revert ErrorsLib.ZeroAddress();

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    vaultAdmin = _vaultAdmin;
  }

  /* EXTERNAL */

  /// @inheritdoc IMoolahVaultFactory
  function createMoolahVault(
    address manager,
    address curator,
    address guardian,
    uint256 timeLockDelay,
    address asset,
    string memory name,
    string memory symbol,
    bytes32 salt
  ) external returns (address, address, address) {
    require(IERC20Metadata(asset).decimals() == 18, "Asset must have 18 decimals");

    address[] memory managerProposers = new address[](1);
    managerProposers[0] = manager;
    address[] memory managerExecutors = new address[](1);
    managerExecutors[0] = manager;

    address[] memory curatorProposers = new address[](1);
    curatorProposers[0] = curator;
    address[] memory curatorExecutors = new address[](1);
    curatorExecutors[0] = curator;

    /// create timeLock
    TimeLock managerTimeLock = new TimeLock(
      managerProposers,
      managerExecutors,
      address(this),
      timeLockDelay
    );

    {
      // transfer roles
      managerTimeLock.grantRole(CANCELLER_ROLE, guardian);
      managerTimeLock.grantRole(DEFAULT_ADMIN_ROLE, address(managerTimeLock));
      managerTimeLock.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    TimeLock curatorTimeLock = new TimeLock(
      curatorProposers,
      curatorExecutors,
      address(this),
      timeLockDelay
    );

    {
      // transfer roles
      curatorTimeLock.grantRole(CANCELLER_ROLE, guardian);
      curatorTimeLock.grantRole(DEFAULT_ADMIN_ROLE, address(curatorTimeLock));
      curatorTimeLock.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(MOOLAH_VAULT_IMPL_18),
      abi.encodeWithSignature("initialize(address,address,address,string,string)", address(this), address(this), asset, name, symbol)
    );

    {
      // transfer roles
      IMoolahVault vault = IMoolahVault(address(proxy));

      vault.grantRole(DEFAULT_ADMIN_ROLE, vaultAdmin);
      vault.grantRole(MANAGER, address(managerTimeLock));
      vault.grantRole(CURATOR, address(curatorTimeLock));

      vault.revokeRole(CURATOR, address(this));
      vault.revokeRole(MANAGER, address(this));
      vault.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    isMoolahVault[address(proxy)] = true;

    emit EventsLib.CreateMoolahVault(
      address(proxy),
      address(MOOLAH_VAULT_IMPL_18),
      address(managerTimeLock),
      address(curatorTimeLock),
      timeLockDelay,
      msg.sender,
      manager,
      curator,
      guardian,
      asset,
      name,
      symbol,
      salt
    );

    return (address(proxy), address(managerTimeLock), address(curatorTimeLock));
  }

  function setVaultAdmin(address _vaultAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_vaultAdmin == address(0)) revert ErrorsLib.ZeroAddress();
    if (_vaultAdmin == vaultAdmin) revert ErrorsLib.AlreadySet();
    vaultAdmin = _vaultAdmin;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IMoolahVault } from "./interfaces/IMoolahVault.sol";
import { IMoolahVaultFactory } from "./interfaces/IMoolahVaultFactory.sol";
import { TimeLock } from "timelock/TimeLock.sol";

import { EventsLib } from "./libraries/EventsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";

import { MoolahVault } from "./MoolahVault.sol";

/// @title MoolahVaultFactory
/// @notice This contract allows to create MoolahVault, and to index them easily.
contract MoolahVaultFactory is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IMoolahVaultFactory {
  /* IMMUTABLES */

  /// @inheritdoc IMoolahVaultFactory
  address public immutable MOOLAH;

  address public vaultAdmin;

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
    address initialManager,
    address asset,
    string memory name,
    string memory symbol,
    bytes32 salt
  ) external returns (address, address) {

    address[] memory proposers = new address[](1);
    proposers[0] = initialManager;
    address[] memory executors = new address[](1);
    executors[0] = initialManager;

    /// create timeLock
    TimeLock timeLock = new TimeLock(
      proposers,
      executors,
     address(this)
    );

    {
      // transfer roles
      timeLock.grantRole(timeLock.CANCELLER_ROLE(), initialManager);
      timeLock.grantRole(timeLock.DEFAULT_ADMIN_ROLE(), address(timeLock));
      timeLock.revokeRole(timeLock.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // create the vault
    MoolahVault impl = new MoolahVault{salt: salt}(MOOLAH, asset);

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, vaultAdmin, initialManager, asset, name, symbol)
    );

    isMoolahVault[address(proxy)] = true;

    emit EventsLib.CreateMoolahVault(
      address(proxy), address(impl), address(timeLock), msg.sender, initialManager,  asset, name, symbol, salt
    );

    return (address(proxy), address(timeLock));
  }

  function setVaultAdmin(address _vaultAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_vaultAdmin == address(0)) revert ErrorsLib.ZeroAddress();
    if (_vaultAdmin == vaultAdmin) revert ErrorsLib.AlreadySet();
    vaultAdmin = _vaultAdmin;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

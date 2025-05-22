// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMoolahVault } from "./IMoolahVault.sol";

/// @title IMoolahVaultFactory
/// @notice Interface of MoolahVault's factory.
interface IMoolahVaultFactory {
  /// @notice The address of the Moolah contract.
  function MOOLAH() external view returns (address);

  /// @notice Whether a MoolahVault was created with the factory.
  function isMoolahVault(address target) external view returns (bool);

  /// @notice Creates a new MoolahVault.
  /// @param manager The manager of the vault.
  /// @param curator The curator of the vault.
  /// @param guardian The guardian of the vault.
  /// @param timeLockDelay The delay for the time lock.
  /// @param asset The address of the underlying asset.
  /// @param name The name of the vault.
  /// @param symbol The symbol of the vault.
  /// @param salt The salt to use for the MetaMorpho vault's CREATE2 address.
  function createMoolahVault(
    address manager,
    address curator,
    address guardian,
    uint256 timeLockDelay,
    address asset,
    string memory name,
    string memory symbol,
    bytes32 salt
  ) external returns (address vault, address managerTimeLock, address curatorTimeLock);
}

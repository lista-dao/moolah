// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ErrorsLib
/// @author Lista DAO
/// @notice Library exposing error messages.
library ErrorsLib {
  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";

  /// @dev Thrown when the caller is not Moolah.
  string internal constant NOT_MOOLAH = "not Moolah";

  /// @notice Thrown when the caller is not the admin.
  string internal constant NOT_ADMIN = "not admin";
}

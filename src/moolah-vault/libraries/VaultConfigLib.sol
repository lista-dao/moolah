// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { EventsLib } from "./EventsLib.sol";

/// @title VaultConfigLib
/// @author Lista DAO
/// @notice External library for MoolahVault configuration operations — reduces vault runtime bytecode below EIP-170 limit.
/// @dev Functions are `public` so the compiler emits DELEGATECALL to this separately-deployed library.
library VaultConfigLib {
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @notice Add or remove an account from the whitelist.
  /// @param _whiteList  Whitelist set (storage ref from vault)
  /// @param account  The account to add or remove
  /// @param enabled  True to add, false to remove
  function setWhiteList(EnumerableSet.AddressSet storage _whiteList, address account, bool enabled) public {
    if (account == address(0)) revert ErrorsLib.ZeroAddress();
    if (enabled) {
      if (_whiteList.contains(account)) revert ErrorsLib.AlreadySet();
      _whiteList.add(account);
    } else {
      if (!_whiteList.contains(account)) revert ErrorsLib.NotSet();
      _whiteList.remove(account);
    }

    emit EventsLib.SetWhiteList(account, enabled);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Id, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { MarketConfig } from "./PendingLib.sol";
import { ConstantsLib } from "./ConstantsLib.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { EventsLib } from "./EventsLib.sol";

/// @title VaultConfigLib
/// @author Lista DAO
/// @notice External library for MoolahVault configuration operations — reduces vault runtime bytecode below EIP-170 limit.
/// @dev Functions are `public` so the compiler emits DELEGATECALL to this separately-deployed library.
///      `address(this)` inside these functions resolves to the calling vault contract.
///      `msg.sender` inside these functions resolves to the original external caller (DELEGATECALL preserves).
library VaultConfigLib {
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @notice Validate and set the supply queue.
  /// @param _config   Market config mapping (storage ref from vault)
  /// @param _supplyQueue  Supply queue array (storage ref from vault)
  /// @param newSupplyQueue  New supply queue to set
  function setSupplyQueue(
    mapping(Id => MarketConfig) storage _config,
    Id[] storage _supplyQueue,
    Id[] calldata newSupplyQueue
  ) public {
    uint256 length = newSupplyQueue.length;

    if (length > ConstantsLib.MAX_QUEUE_LENGTH) revert ErrorsLib.MaxQueueLengthExceeded();

    for (uint256 i; i < length; ++i) {
      if (_config[newSupplyQueue[i]].cap == 0) revert ErrorsLib.UnauthorizedMarket(newSupplyQueue[i]);
    }

    // Overwrite storage array (cannot directly assign to storage reference in library)
    while (_supplyQueue.length > 0) {
      _supplyQueue.pop();
    }
    for (uint256 i; i < length; ++i) {
      _supplyQueue.push(newSupplyQueue[i]);
    }

    emit EventsLib.SetSupplyQueue(msg.sender, newSupplyQueue);
  }

  /// @notice Validate indexes, rebuild withdraw queue, and clean up removed markets.
  /// @param _config   Market config mapping (storage ref from vault)
  /// @param _withdrawQueue  Withdraw queue array (storage ref from vault)
  /// @param moolah  Moolah protocol instance (immutable in vault, passed as param)
  /// @param indexes  New index ordering for the withdraw queue
  function updateWithdrawQueue(
    mapping(Id => MarketConfig) storage _config,
    Id[] storage _withdrawQueue,
    IMoolah moolah,
    uint256[] calldata indexes
  ) public {
    uint256 newLength = indexes.length;
    uint256 currLength = _withdrawQueue.length;

    bool[] memory seen = new bool[](currLength);
    Id[] memory newWithdrawQueue = new Id[](newLength);

    for (uint256 i; i < newLength; ++i) {
      uint256 prevIndex = indexes[i];

      // If prevIndex >= currLength, it will revert with native "Index out of bounds".
      Id id = _withdrawQueue[prevIndex];
      if (seen[prevIndex]) revert ErrorsLib.DuplicateMarket(id);
      seen[prevIndex] = true;

      newWithdrawQueue[i] = id;
    }

    for (uint256 i; i < currLength; ++i) {
      if (!seen[i]) {
        Id id = _withdrawQueue[i];

        if (_config[id].cap != 0) revert ErrorsLib.InvalidMarketRemovalNonZeroCap(id);

        if (moolah.position(id, address(this)).supplyShares != 0) {
          if (_config[id].removableAt == 0) revert ErrorsLib.InvalidMarketRemovalNonZeroSupply(id);

          if (block.timestamp < _config[id].removableAt) {
            revert ErrorsLib.InvalidMarketRemovalTimelockNotElapsed(id);
          }
        }

        delete _config[id];
      }
    }

    // Overwrite storage array
    while (_withdrawQueue.length > 0) {
      _withdrawQueue.pop();
    }
    for (uint256 i; i < newLength; ++i) {
      _withdrawQueue.push(newWithdrawQueue[i]);
    }

    emit EventsLib.SetWithdrawQueue(msg.sender, newWithdrawQueue);
  }

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

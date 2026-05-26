// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IBrokerInterestLockBuffer } from "./interfaces/IBrokerInterestLockBuffer.sol";

/// @title BrokerInterestLockBuffer
/// @author Lista DAO
/// @notice Per-vault smoothing buffer for brokered-interest flushes (audit #08).
contract BrokerInterestLockBuffer is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IBrokerInterestLockBuffer {
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant RELAYER = keccak256("RELAYER");

  uint64 public constant MIN_DURATION = 1 hours;
  uint64 public constant MAX_DURATION = 3 days;

  address public override vault;
  address public override asset;

  uint128 public override lockedAmount;
  uint64 public override lastUpdate;
  uint64 public override duration;

  uint256[45] private __gap;

  event BrokerInterestNotified(address indexed relayer, uint256 amount, uint256 newLocked, uint256 unlockEnd);
  event SetDuration(uint64 newDuration);

  error ZeroAddress();
  error InvalidDuration();
  error LockedOverflow();

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _admin,
    address _manager,
    address _vault,
    address _asset,
    uint64 _duration
  ) external initializer {
    if (_admin == address(0) || _manager == address(0) || _vault == address(0) || _asset == address(0)) {
      revert ZeroAddress();
    }
    if (_duration < MIN_DURATION || _duration > MAX_DURATION) revert InvalidDuration();

    __AccessControlEnumerable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);

    vault = _vault;
    asset = _asset;
    duration = _duration;
  }

  function currentLocked() public view override returns (uint256) {
    uint64 dur = duration;
    if (dur == 0) return 0;
    uint256 elapsed = block.timestamp - lastUpdate;
    if (elapsed >= dur) return 0;
    return (uint256(lockedAmount) * (dur - elapsed)) / dur;
  }

  /// @dev Combine-and-reset: clock restarts each notify; duration unchanged here.
  function notifyBrokerInterest(uint256 amount) external override onlyRole(RELAYER) {
    uint256 newLocked = currentLocked() + amount;
    if (newLocked > type(uint128).max) revert LockedOverflow();

    lockedAmount = uint128(newLocked);
    lastUpdate = uint64(block.timestamp);

    emit BrokerInterestNotified(msg.sender, amount, newLocked, block.timestamp + duration);
  }

  /// @dev Rebase under old curve so already-revealed value stays revealed and currentLocked() is
  ///      continuous across the call (else lowering duration would unlock the remainder in one block).
  function setDuration(uint64 newDuration) external onlyRole(MANAGER) {
    if (newDuration < MIN_DURATION || newDuration > MAX_DURATION) revert InvalidDuration();

    lockedAmount = uint128(currentLocked());
    lastUpdate = uint64(block.timestamp);
    duration = newDuration;

    emit SetDuration(newDuration);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { IIrm } from "moolah/interfaces/IIrm.sol";
import { IFixedRateIrm } from "./interfaces/IFixedRateIrm.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams, Market } from "moolah/interfaces/IMoolah.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";

/* ERRORS */

/// @dev Thrown when the rate is already set for this market.
string constant RATE_SET = "rate set";
/// @dev Thrown when the rate is negative.
string constant RATE_INVALID = "negative rate";
/// @dev Thrown when trying to set a rate that is too high.
string constant RATE_TOO_HIGH = "rate too high";

/// @title FixedRateIrm
/// @author Lista DAO
contract FixedRateIrm is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IFixedRateIrm {
  using MarketParamsLib for MarketParams;

  /* EVENTS */

  /// @notice Emitted when a borrow rate is updated.
  event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

  /// @notice Emitted when the minimum cap is updated.
  event MinCapUpdate(uint256 oldMinCap, uint256 newMinCap);

  /// @notice Emitted when the borrow rate cap for a market is updated.
  event BorrowRateCapUpdate(Id indexed id, uint256 oldRateCap, uint256 newRateCap);

  /// @notice Emitted when the borrow rate floor for a market is updated.
  event BorrowRateFloorUpdate(Id indexed id, uint256 oldRateFloor, uint256 newRateFloor);

  /* CONSTANTS */

  /// @inheritdoc IFixedRateIrm
  int256 public constant MAX_BORROW_RATE = 8.0 ether / int256(365 days);

  /* STORAGE */

  /// @inheritdoc IFixedRateIrm
  mapping(Id => int256) public borrowRateStored;

  /// @inheritdoc IFixedRateIrm
  mapping(Id => uint256) public rateCap;

  /// @inheritdoc IFixedRateIrm
  uint256 public minCap;

  /// @inheritdoc IFixedRateIrm
  mapping(Id => uint256) public rateFloor;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Constructor.
  /// @param admin The new admin of the contract.
  function initialize(address admin, address manager) public initializer {
    require(admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(manager != address(0), ErrorsLib.ZERO_ADDRESS);

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  /* SETTER */

  /// @inheritdoc IFixedRateIrm
  function setBorrowRate(Id id, int256 newBorrowRate) external onlyRole(BOT) {
    require(newBorrowRate >= 0, RATE_INVALID);
    require(newBorrowRate <= MAX_BORROW_RATE, RATE_TOO_HIGH);
    require(borrowRateStored[id] != newBorrowRate, RATE_SET);

    if (rateCap[id] != 0) {
      require(newBorrowRate <= int256(rateCap[id]), "rate exceeds cap");
    }

    if (rateFloor[id] != 0) {
      require(newBorrowRate >= int256(rateFloor[id]), "rate below floor");
    }

    borrowRateStored[id] = newBorrowRate;

    emit SetBorrowRate(id, newBorrowRate);
  }

  /// @dev Updates the borrow rate cap for a market. The new cap must be >= minCap.
  function updateRateCap(Id id, uint256 newRateCap) external onlyRole(BOT) {
    uint256 oldCap = rateCap[id];
    require(newRateCap >= minCap && newRateCap != oldCap && newRateCap <= uint256(MAX_BORROW_RATE), "invalid rate cap");
    require(rateFloor[id] <= newRateCap, "invalid new cap vs floor");

    rateCap[id] = newRateCap;

    emit BorrowRateCapUpdate(id, oldCap, newRateCap);
  }

  /// @dev Updates the minimum borrow rate for a market.
  function updateRateFloor(Id id, uint256 newRateFloor) external onlyRole(BOT) {
    uint256 oldFloor = rateFloor[id];
    require(newRateFloor != oldFloor, "invalid rate floor");

    // rate floor must be <= rate cap
    uint256 _cap = rateCap[id] != 0 ? rateCap[id] : uint256(MAX_BORROW_RATE);
    if (_cap < minCap) _cap = minCap;
    require(newRateFloor <= _cap, "invalid rate floor vs cap");

    rateFloor[id] = newRateFloor;

    emit BorrowRateFloorUpdate(id, oldFloor, newRateFloor);
  }

  /// @dev Updates the minimum borrow rate cap for all markets.
  function updateMinCap(uint256 newMinCap) external onlyRole(MANAGER) {
    uint256 oldMinCap = minCap;
    require(newMinCap > 0 && newMinCap != oldMinCap && newMinCap <= uint256(MAX_BORROW_RATE), "invalid min cap");
    minCap = newMinCap;

    emit MinCapUpdate(oldMinCap, newMinCap);
  }

  /* BORROW RATES */

  /// @inheritdoc IIrm
  function borrowRateView(MarketParams memory marketParams, Market memory) public view returns (uint256) {
    Id id = marketParams.id();
    int256 borrowRateCached = borrowRateStored[id];
    require(borrowRateCached >= 0, RATE_INVALID);
    int256 _borrowRate = borrowRateCached > MAX_BORROW_RATE ? MAX_BORROW_RATE : borrowRateCached;
    uint256 rate = uint256(_borrowRate);

    uint256 _cap = rateCap[id] != 0 ? rateCap[id] : uint256(MAX_BORROW_RATE);
    if (_cap < minCap) _cap = minCap;
    if (rate > _cap) rate = _cap;
    // Adjust rate to make sure the rate >= floor
    uint256 floor = rateFloor[id];
    if (rate < floor) rate = floor;
    return rate;
  }

  /// @inheritdoc IIrm
  /// @dev Reverts on not set rate, so the rate has to be set before the market creation.
  function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
    return borrowRateView(marketParams, market);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

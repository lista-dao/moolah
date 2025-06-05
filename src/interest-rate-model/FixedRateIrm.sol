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
/// @dev Thrown when the rate is zero or negative.
string constant RATE_INVALID = "rate zero or negative";
/// @dev Thrown when trying to set a rate that is too high.
string constant RATE_TOO_HIGH = "rate too high";

/// @title FixedRateIrm
/// @author Lista DAO
contract FixedRateIrm is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IFixedRateIrm {
  using MarketParamsLib for MarketParams;

  /* CONSTANTS */

  /// @inheritdoc IFixedRateIrm
  int256 public constant MAX_BORROW_RATE = 8.0 ether / int256(365 days);

  /* STORAGE */

  /// @inheritdoc IFixedRateIrm
  mapping(Id => int256) public borrowRateStored;

  bytes32 public constant MANAGER = keccak256("MANAGER");

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
  function setBorrowRate(Id id, int256 newBorrowRate) external onlyRole(MANAGER) {
    require(newBorrowRate > 0, RATE_INVALID);
    require(newBorrowRate <= MAX_BORROW_RATE, RATE_TOO_HIGH);
    require(borrowRateStored[id] != newBorrowRate, RATE_SET);

    borrowRateStored[id] = newBorrowRate;

    emit SetBorrowRate(id, newBorrowRate);
  }

  /* BORROW RATES */

  /// @inheritdoc IIrm
  function borrowRateView(MarketParams memory marketParams, Market memory) external view returns (uint256) {
    int256 borrowRateCached = borrowRateStored[marketParams.id()];
    require(borrowRateCached > 0, RATE_INVALID);
    int256 _borrowRate = borrowRateCached > MAX_BORROW_RATE ? MAX_BORROW_RATE : borrowRateCached;
    return uint256(_borrowRate);
  }

  /// @inheritdoc IIrm
  /// @dev Reverts on not set rate, so the rate has to be set before the market creation.
  function borrowRate(MarketParams memory marketParams, Market memory) external view returns (uint256) {
    int256 borrowRateCached = borrowRateStored[marketParams.id()];
    require(borrowRateCached > 0, RATE_INVALID);
    int256 _borrowRate = borrowRateCached > MAX_BORROW_RATE ? MAX_BORROW_RATE : borrowRateCached;
    return uint256(_borrowRate);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

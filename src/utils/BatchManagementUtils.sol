// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IMoolah, Id, MarketParams } from "moolah/interfaces/IMoolah.sol";
import { FixedTermAndRate } from "../broker/interfaces/IBroker.sol";

interface ILendingBrokerBot {
  function updateFixedTermAndRate(FixedTermAndRate calldata term, bool removeTerm) external;

  function refinanceMaturedFixedPositions(address user, uint256[] calldata posIds) external;
}

contract BatchManagementUtils is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  address public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  event SetWhitelist(address indexed to, bool status);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address moolah) {
    require(moolah != address(0), "moolah is zero address");
    _disableInitializers();

    MOOLAH = moolah;
  }

  /** @dev Initializer function to set up roles and initial state.
   * @param admin The address to be granted the DEFAULT_ADMIN_ROLE.
   * @param manager The address to be granted the MANAGER role.
   *
   * Requirements:
   * - `admin` must not be the zero address.
   * - `manager` must not be the zero address.
   */
  function initialize(address admin, address manager) public initializer {
    require(admin != address(0), "admin is zero address");
    require(manager != address(0), "manager is zero address");
    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  /**
   * @dev Set market fee for multiple markets in a single transaction.
   * @param ids The array of market IDs.
   * @param fees The array of fees corresponding to each market ID.
   *
   * Requirements:
   * - Caller must have the MANAGER role for the specified `moolah` contract.
   * - `ids` and `fees` arrays must have the same length and be non-empty.
   * - Each market ID in `ids` must correspond to an existing market in the `moolah` contract.
   */
  function batchSetMarketFee(Id[] calldata ids, uint256[] calldata fees) external {
    require(IAccessControl(MOOLAH).hasRole(MANAGER, msg.sender), "Not manager of moolah");
    require(ids.length == fees.length && ids.length > 0, "Array length mismatch");

    for (uint256 i = 0; i < ids.length; i++) {
      MarketParams memory marketParams = IMoolah(MOOLAH).idToMarketParams(ids[i]);
      require(marketParams.loanToken != address(0), "Market not created");
      IMoolah(MOOLAH).setFee(marketParams, fees[i]);
    }
  }

  /**
   * @dev Update fixed term and rate across multiple LendingBrokers in a single transaction.
   * @param brokers The array of LendingBroker addresses.
   * @param terms The array of fixed term and rate schemes corresponding to each broker.
   * @param removes The array of flags indicating whether to remove the term (true) or add/update it (false).
   *
   * Requirements:
   * - Caller must have the BOT role on every broker in `brokers`.
   * - This contract must also have the BOT role on every broker in `brokers` so it can forward the call.
   * - All three arrays must have the same length and be non-empty.
   */
  function batchUpdateFixedTermAndRate(
    address[] calldata brokers,
    FixedTermAndRate[] calldata terms,
    bool[] calldata removes
  ) external {
    require(
      brokers.length == terms.length && brokers.length == removes.length && brokers.length > 0,
      "Array length mismatch"
    );
    for (uint256 i = 0; i < brokers.length; i++) {
      require(IAccessControl(brokers[i]).hasRole(BOT, msg.sender), "Not bot of broker");
      ILendingBrokerBot(brokers[i]).updateFixedTermAndRate(terms[i], removes[i]);
    }
  }

  /**
   * @dev Refinance matured fixed positions for multiple (broker, user) pairs in a single transaction.
   * @param brokers The array of LendingBroker addresses.
   * @param users The array of users whose matured fixed positions will be refinanced.
   * @param posIds The array of posId arrays, one per (broker, user) pair.
   *
   * Requirements:
   * - Caller must have the BOT role on every broker in `brokers`.
   * - This contract must also have the BOT role on every broker in `brokers` so it can forward the call.
   * - All three arrays must have the same length and be non-empty.
   */
  function batchRefinance(address[] calldata brokers, address[] calldata users, uint256[][] calldata posIds) external {
    require(
      brokers.length == users.length && brokers.length == posIds.length && brokers.length > 0,
      "Array length mismatch"
    );
    for (uint256 i = 0; i < brokers.length; i++) {
      require(IAccessControl(brokers[i]).hasRole(BOT, msg.sender), "Not bot of broker");
      ILendingBrokerBot(brokers[i]).refinanceMaturedFixedPositions(users[i], posIds[i]);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IMoolah, Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract BatchManagementUtils is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  address public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER");

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

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { ICreditBroker, FixedLoanPosition, GraceConfig, FixedTermType } from "./interfaces/ICreditBroker.sol";
import { CreditBrokerMath, RATE_SCALE } from "./libraries/CreditBrokerMath.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";

contract CreditBrokerInfo is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin) public initializer {
    require(admin != address(0), "Zero address");
    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /**
   * @dev Get the current debt (principal + interest) of a fixed loan position
   * @param broker The credit broker address
   * @param user The address of the user
   * @param posId The ID of the fixed position
   */
  function getPositionDebt(address broker, address user, uint256 posId) external view returns (uint256, uint256) {
    FixedLoanPosition memory position = ICreditBroker(broker).getPosition(user, posId);

    return CreditBrokerMath.getPositionDebt(position);
  }

  /**
   * @dev Get the total principal and interest of all fixed loan positions of a user
   * @param broker The credit broker address
   * @param user The address of the user
   */
  function getTotalPrincipalAndInterest(
    address broker,
    address user
  ) external view returns (uint256 totalPrincipal, uint256 totalInterest) {
    ICreditBroker _broker = ICreditBroker(broker);
    FixedLoanPosition[] memory positions = _broker.userFixedPositions(user);

    for (uint256 i = 0; i < positions.length; i++) {
      (uint256 principal, uint256 interest) = CreditBrokerMath.getPositionDebt(positions[i]);
      totalPrincipal += principal;
      totalInterest += interest;
    }
  }

  /**
   * @dev Get the total debt (principal + interest) of a user
   * @param _broker The credit broker address
   */
  function getUserTotalDebt(address _broker, address user) external view returns (uint256 totalDebt) {
    ICreditBroker broker = ICreditBroker(_broker);
    totalDebt = broker.getUserTotalDebt(user);
  }

  /**
   * @dev Get all fixed loan positions of a user
   * @param broker The credit broker address
   * @param user The address of the user
   */
  function getUserFixedPositions(address broker, address user) external view returns (FixedLoanPosition[] memory) {
    return ICreditBroker(broker).userFixedPositions(user);
  }

  /**
   * @dev Get the fixed loan position info
   * @param broker The credit broker address
   * @param user The address of the user
   * @param posId The ID of the fixed position
   */
  function getPosition(address broker, address user, uint256 posId) external view returns (FixedLoanPosition memory) {
    return ICreditBroker(broker).getPosition(user, posId);
  }

  /**
   * @dev Get the maximum LISTA amount that can be used to repay interest for a fixed position
   * @param broker The credit broker address
   * @param user The address of the user
   * @param posId The ID of the fixed position
   * @return maxListaToRepay The maximum LISTA amount
   */
  function getMaxListaToRepay(
    address broker,
    address user,
    uint256 posId
  ) external view returns (uint256 maxListaToRepay) {
    ICreditBroker _broker = ICreditBroker(broker);
    FixedLoanPosition memory position = _broker.getPosition(user, posId);

    IOracle oracle = _broker.ORACLE();
    uint256 listaPrice = oracle.peek(_broker.LISTA());

    return CreditBrokerMath.getMaxListaForInterestRepay(position, listaPrice, _broker.listaDiscountRate());
  }

  /**
   * @dev Preview the interest, penalty and principal repaid
   * @notice for frontend usage, when user is repaying a fixed loan position with certain amount
   * @param broker The credit broker address
   * @param user The address of the user
   * @param repayAmount The amount to repay
   * @param posId The ID of the fixed position to repay
   * @return interestRepaid The interest portion of the repayment
   * @return penalty The penalty portion of the repayment
   * @return principalRepaid The principal portion of the repayment
   */
  function previewRepayFixedLoanPosition(
    address broker,
    address user,
    uint256 posId,
    uint256 repayAmount
  ) external view returns (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) {
    ICreditBroker _broker = ICreditBroker(broker);
    FixedLoanPosition memory position = _broker.getPosition(user, posId);

    (interestRepaid, penalty, principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(
      position,
      repayAmount,
      _broker.getGraceConfig()
    );
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

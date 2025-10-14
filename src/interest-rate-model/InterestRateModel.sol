// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { IIrm } from "moolah/interfaces/IIrm.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";

import { UtilsLib } from "./libraries/UtilsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { ExpLib } from "./libraries/ExpLib.sol";
import { MathLib, WAD_INT as WAD } from "./libraries/MathLib.sol";
import { ConstantsLib } from "./libraries/ConstantsLib.sol";
import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams, Market } from "moolah/interfaces/IMoolah.sol";
import { MathLib as MoolahMathLib } from "moolah/libraries/MathLib.sol";

/// @title InterestRateModel
/// @author Lista DAO
contract InterestRateModel is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IInterestRateModel {
  using MathLib for int256;
  using UtilsLib for int256;
  using MoolahMathLib for uint128;
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

  /* IMMUTABLES */

  /// @inheritdoc IInterestRateModel
  address public immutable MOOLAH;

  /* STORAGE */

  /// @inheritdoc IInterestRateModel
  mapping(Id => int256) public rateAtTarget;

  /// @inheritdoc IInterestRateModel
  mapping(Id => uint256) public rateCap;

  /// @inheritdoc IInterestRateModel
  uint256 public minCap;

  /// @inheritdoc IInterestRateModel
  mapping(Id => uint256) public rateFloor;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    require(moolah != address(0), ErrorsLib.ZERO_ADDRESS);
    _disableInitializers();
    MOOLAH = moolah;
  }

  /// @notice Constructor.
  /// @param admin The new admin of the contract.
  function initialize(address admin) public initializer {
    require(admin != address(0), ErrorsLib.ZERO_ADDRESS);

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /* BORROW RATES */

  /// @inheritdoc IIrm
  function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
    (uint256 avgRate, ) = _borrowRate(marketParams.id(), market);
    return avgRate;
  }

  /// @inheritdoc IIrm
  function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
    require(msg.sender == MOOLAH, ErrorsLib.NOT_MOOLAH);

    Id id = marketParams.id();

    (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

    rateAtTarget[id] = endRateAtTarget;

    // Safe "unchecked" cast because endRateAtTarget >= 0.
    emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

    return avgRate;
  }

  /// @dev Returns avgRate and endRateAtTarget.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
    // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
    int256 utilization = int256(
      market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0
    );

    int256 errNormFactor = utilization > ConstantsLib.TARGET_UTILIZATION
      ? WAD - ConstantsLib.TARGET_UTILIZATION
      : ConstantsLib.TARGET_UTILIZATION;
    int256 err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(errNormFactor);

    int256 startRateAtTarget = rateAtTarget[id];

    int256 avgRateAtTarget;
    int256 endRateAtTarget;

    if (startRateAtTarget == 0) {
      // First interaction.
      avgRateAtTarget = ConstantsLib.INITIAL_RATE_AT_TARGET;
      endRateAtTarget = ConstantsLib.INITIAL_RATE_AT_TARGET;
    } else {
      // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
      // So the rate is always underestimated.
      int256 speed = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(err);
      // market.lastUpdate != 0 because it is not the first interaction with this market.
      // Safe "unchecked" cast because block.timestamp - market.lastUpdate <= block.timestamp <= type(int256).max.
      int256 elapsed = int256(block.timestamp - market.lastUpdate);
      int256 linearAdaptation = speed * elapsed;

      if (linearAdaptation == 0) {
        // If linearAdaptation == 0, avgRateAtTarget = endRateAtTarget = startRateAtTarget;
        avgRateAtTarget = startRateAtTarget;
        endRateAtTarget = startRateAtTarget;
      } else {
        // Formula of the average rate that should be returned to Moolah:
        // avg = 1/T * ∫_0^T curve(startRateAtTarget*exp(speed*x), err) dx
        // The integral is approximated with the trapezoidal rule:
        // avg ~= 1/T * Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / 2 * T/N
        // Where f(x) = startRateAtTarget*exp(speed*x)
        // avg ~= Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / (2 * N)
        // As curve is linear in its first argument:
        // avg ~= curve([Σ_i=1^N [f((i-1) * T/N) + f(i * T/N)] / (2 * N), err)
        // avg ~= curve([(f(0) + f(T))/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
        // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
        // With N = 2:
        // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + startRateAtTarget*exp(speed*T/2)] / 2, err)
        // avg ~= curve([startRateAtTarget + endRateAtTarget + 2*startRateAtTarget*exp(speed*T/2)] / 4, err)
        endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
        int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
        avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
      }
    }

    uint256 _cap = rateCap[id] != 0 ? rateCap[id] : ConstantsLib.DEFAULT_RATE_CAP;
    if (_cap < minCap) _cap = minCap;
    // Safe "unchecked" cast because avgRateAtTarget >= 0.
    uint256 avgRate = uint256(_curve(avgRateAtTarget, err));
    if (avgRate > _cap) avgRate = _cap;

    // Adjust rate to make sure the rate >= floor
    uint256 floor = rateFloor[id];
    require(floor <= _cap, "invalid floor");
    if (avgRate < floor) avgRate = floor;

    return (avgRate, endRateAtTarget);
  }

  /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
  /// The formula of the curve is the following:
  /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
  ///     ((C-1)*err + 1) * rateAtTarget else.
  function _curve(int256 _rateAtTarget, int256 err) private pure returns (int256) {
    // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
    int256 coeff = err < 0 ? WAD - WAD.wDivToZero(ConstantsLib.CURVE_STEEPNESS) : ConstantsLib.CURVE_STEEPNESS - WAD;
    // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
    return (coeff.wMulToZero(err) + WAD).wMulToZero(int256(_rateAtTarget));
  }

  /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
  /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
  function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) private pure returns (int256) {
    // Non negative because MIN_RATE_AT_TARGET > 0.
    return
      startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(
        ConstantsLib.MIN_RATE_AT_TARGET,
        ConstantsLib.MAX_RATE_AT_TARGET
      );
  }

  /// @dev Updates the borrow rate cap for a market. The new cap must be >= minCap.
  function updateRateCap(Id id, uint256 newRateCap) external onlyRole(BOT) {
    uint256 oldCap = rateCap[id];
    require(newRateCap >= minCap && newRateCap != oldCap, "invalid rate cap");
    rateCap[id] = newRateCap;

    emit BorrowRateCapUpdate(id, oldCap, newRateCap);
  }

  /// @dev Updates the minimum borrow rate for a market.
  function updateRateFloor(Id id, uint256 newRateFloor) external onlyRole(BOT) {
    uint256 oldFloor = rateFloor[id];
    require(newRateFloor != oldFloor, "invalid rate floor");

    // rate floor must be <= rate cap
    uint256 _cap = rateCap[id] != 0 ? rateCap[id] : ConstantsLib.DEFAULT_RATE_CAP;
    if (_cap < minCap) _cap = minCap;
    require(newRateFloor <= _cap, "invalid rate floor vs cap");

    rateFloor[id] = newRateFloor;

    emit BorrowRateFloorUpdate(id, oldFloor, newRateFloor);
  }

  /// @dev Updates the minimum borrow rate cap for all markets.
  function updateMinCap(uint256 newMinCap) external onlyRole(MANAGER) {
    uint256 oldMinCap = minCap;
    require(newMinCap > 0 && newMinCap != oldMinCap && newMinCap <= ConstantsLib.DEFAULT_RATE_CAP, "invalid min cap");
    minCap = newMinCap;

    emit MinCapUpdate(oldMinCap, newMinCap);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

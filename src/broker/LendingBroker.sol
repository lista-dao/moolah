// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate, LiquidationContext } from "./interfaces/IBroker.sol";
import { IRateCalculator } from "./interfaces/IRateCalculator.sol";
import { BrokerMath, RATE_SCALE } from "./libraries/BrokerMath.sol";
import { IBrokerInterestRelayer } from "./interfaces/IBrokerInterestRelayer.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { IMoolahLiquidateCallback } from "../moolah/interfaces/IMoolahCallbacks.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

/// @title Broker for Lista Lending
/// @author Lista DAO
/// @notice This contract allows users to borrow token(LisUSD in general) by depositing collateral to moolah
/// @dev
/// - all borrow and repay has to be done through the broker, broker manages the positions
/// - User can have multiple fixed rate & terms position and a single dynamic position at the same time
contract LendingBroker is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  IBroker
{
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  using UtilsLib for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;

  // ------- Roles -------
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");

  // ------- Immutables -------
  IMoolah public immutable MOOLAH;
  address public immutable RELAYER;
  IOracle public immutable ORACLE;
  address public LOAN_TOKEN;
  address public COLLATERAL_TOKEN;
  Id public MARKET_ID;
  string public BROKER_NAME;

  // ------- State variables -------

  // --- Dynamic rate loan
  /// @dev user => dynamic loan position
  mapping(address => DynamicLoanPosition) public dynamicLoanPositions;
  /// @dev rate calculator
  address public rateCalculator;

  // --- Fixed rate and terms ---
  /// @dev Fixed term and rate products
  FixedTermAndRate[] public fixedTerms;
  /// @dev user => fixed loan positions
  mapping(address => FixedLoanPosition[]) public fixedLoanPositions;
  /// @dev global id for fixed loan positions
  uint256 public fixedPosUuid;
  /// @dev how many fixed loan positions a user can have
  uint256 public maxFixedLoanPositions;

  // --- switch ---
  /// @dev if true, new borrow will be paused
  bool public borrowPaused;

  // --- liquidation ---
  /// @dev stores the context of an ongoing liquidation
  ///      will be cleared after liquidation
  LiquidationContext private liquidationContext;
  /// @dev liquidation whitelist
  EnumerableSet.AddressSet private liquidationWhitelist;

  // ------- Modifiers -------
  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "Broker/not-moolah");
    _;
  }

  modifier marketIdSet() {
    require(Id.unwrap(MARKET_ID) != bytes32(0), "Broker/market-not-set");
    _;
  }

  modifier whenBorrowNotPaused() {
    require(!borrowPaused, "Broker/borrow-paused");
    _;
  }

  /**
   * @dev Constructor for the LendingBroker contract
   * @param moolah The address of the Moolah contract
   * @param relayer The address of the BrokerInterestRelayer contract
   * @param oracle The address of the oracle
   */
  constructor(address moolah, address relayer, address oracle) {
    // zero address assert
    require(moolah != address(0) && relayer != address(0) && oracle != address(0), "broker/zero-address-provided");
    // set addresses
    MOOLAH = IMoolah(moolah);
    RELAYER = relayer;
    ORACLE = IOracle(oracle);

    _disableInitializers();
  }

  /**
   * @dev Initialize the LendingBroker contract
   * @param _admin The address of the admin
   * @param _manager The address of the manager
   * @param _bot The address of the bot
   * @param _pauser The address of the pauser
   * @param _rateCalculator The address of the rate calculator
   * @param _maxFixedLoanPositions The maximum number of fixed loan positions a user can have
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address _rateCalculator,
    uint256 _maxFixedLoanPositions
  ) public initializer {
    require(
      _admin != address(0) &&
        _manager != address(0) &&
        _bot != address(0) &&
        _pauser != address(0) &&
        _rateCalculator != address(0) &&
        _maxFixedLoanPositions > 0,
      "broker/zero-address-provided"
    );

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    // grant roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);
    _grantRole(PAUSER, _pauser);
    // init state variables
    rateCalculator = _rateCalculator;
    maxFixedLoanPositions = _maxFixedLoanPositions;
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Borrow a fixed amount of loan token with a dynamic rate
   * @param amount The amount to borrow
   */
  function borrow(uint256 amount) external override marketIdSet whenNotPaused whenBorrowNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    address user = msg.sender;
    // get updated rate
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    // calc. normalized debt
    uint256 normalizedDebt = BrokerMath.normalizeBorrowAmount(amount, rate, true);
    // update user's dynamic position
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    position.principal += amount;
    position.normalizedDebt += normalizedDebt;
    // borrow from moolah
    _borrowFromMoolah(user, amount);
    // transfer loan token to user
    IERC20(LOAN_TOKEN).safeTransfer(user, amount);
    // validate positions
    _validatePositions(user);
    // emit event
    emit DynamicLoanPositionBorrowed(user, amount, position.principal);
  }

  /**
   * @dev borrow an fixed amount with fixed term and rate
   *      user is not allowed to alter the position once it has been created
   *      but user can repay the loan at any time
   * @param amount amount to borrow
   * @param termId The ID of the term
   */
  function borrow(
    uint256 amount,
    uint256 termId
  ) external override marketIdSet whenNotPaused whenBorrowNotPaused nonReentrant {
    require(amount > 0, "broker/amount-zero");
    address user = msg.sender;
    require(fixedLoanPositions[user].length < maxFixedLoanPositions, "broker/exceed-max-fixed-positions");
    // borrow from moolah
    _borrowFromMoolah(user, amount);
    // get term by Id
    FixedTermAndRate memory term = _getTermById(termId);
    // prepare position info
    uint256 start = block.timestamp;
    uint256 end = block.timestamp + term.duration;
    // pos uuid increment
    fixedPosUuid++;
    // update state
    fixedLoanPositions[user].push(
      FixedLoanPosition({
        posId: fixedPosUuid,
        principal: amount,
        apr: term.apr,
        start: start,
        end: end,
        lastRepaidTime: start,
        interestRepaid: 0,
        principalRepaid: 0
      })
    );
    // transfer loan token to user
    IERC20(LOAN_TOKEN).safeTransfer(user, amount);
    // validate positions
    _validatePositions(user);
    // emit event
    emit FixedLoanPositionCreated(user, fixedPosUuid, amount, start, end, term.apr, termId);
  }

  /**
   * @dev Repay a Dynamic loan position
   * @param amount The amount to repay
   * @param onBehalf The address of the user whose position to repay
   */
  function repay(uint256 amount, address onBehalf) external override marketIdSet whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    require(onBehalf != address(0), "broker/zero-address");
    address user = msg.sender;
    // get user's dynamic position
    DynamicLoanPosition storage position = dynamicLoanPositions[onBehalf];
    // get updated rate
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    // get net accrued interest
    uint256 accruedInterest = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate).zeroFloorSub(
      position.principal
    );
    // calculate the amount we need to repay for interest and principal
    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 amountLeft = amount - repayInterestAmt;
    uint256 repayPrincipalAmt = amountLeft > position.principal ? position.principal : amountLeft;

    require(repayInterestAmt + repayPrincipalAmt > 0, "broker/nothing-to-repay");

    // record the actual repaid amount for event
    uint256 totalRepaid = 0;

    // (1) Repay interest first
    IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), repayInterestAmt);
    // update position
    position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
      BrokerMath.normalizeBorrowAmount(repayInterestAmt, rate, false)
    );
    // supply interest to moolah vault
    _supplyToMoolahVault(repayInterestAmt);
    totalRepaid += repayInterestAmt;

    // has left to repay principal
    if (repayPrincipalAmt > 0) {
      uint256 principalRepaid = _repayToMoolah(user, onBehalf, repayPrincipalAmt);
      if (principalRepaid > 0) {
        // update position
        position.principal = position.principal.zeroFloorSub(principalRepaid);
        position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
          BrokerMath.normalizeBorrowAmount(principalRepaid, rate, false)
        );
        totalRepaid += principalRepaid;
      }
      // remove position if fully repaid
      if (position.principal == 0) {
        delete dynamicLoanPositions[onBehalf];
      }
    }

    // validate positions
    _validatePositions(onBehalf);

    emit DynamicLoanPositionRepaid(onBehalf, totalRepaid, position.principal);
  }

  /**
   * @dev Repay a Fixed loan position
   * @notice repay interest first then principal, repay amount must larger than interest
   * @param amount The amount to repay
   * @param posId The ID of the fixed position to repay
   * @param onBehalf The address of the user whose position to repay
   */
  function repay(
    uint256 amount,
    uint256 posId,
    address onBehalf
  ) external override marketIdSet whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    require(onBehalf != address(0), "broker/zero-address");
    address user = msg.sender;

    // fetch position (will revert if not found)
    FixedLoanPosition memory position = _getFixedPositionByPosId(onBehalf, posId);
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;
    // get outstanding accrued interest
    uint256 accruedInterest = _getAccruedInterestForFixedPosition(position) - position.interestRepaid;

    // initialize repay amounts
    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 repayPrincipalAmt = amount - repayInterestAmt;

    // repay interest first, it might be zero if user just repaid before
    if (repayInterestAmt > 0) {
      IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), repayInterestAmt);
      // update repaid interest amount
      position.interestRepaid += repayInterestAmt;
      // supply interest into vault as revenue
      _supplyToMoolahVault(repayInterestAmt);
    }

    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // ----- penalty
      // check penalty if user is repaying before expiration
      uint256 penalty = _getPenaltyForFixedPosition(position, UtilsLib.min(repayPrincipalAmt, remainingPrincipal));
      // supply penalty into vault as revenue
      if (penalty > 0) {
        IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), penalty);
        repayPrincipalAmt -= penalty;
        _supplyToMoolahVault(penalty);
      }

      // the rest will be used to repay partially
      uint256 repayablePrincipal = UtilsLib.min(repayPrincipalAmt, remainingPrincipal);
      if (repayablePrincipal > 0) {
        uint256 principalRepaid = _repayToMoolah(user, onBehalf, repayablePrincipal);
        position.principalRepaid += principalRepaid;
        // reset repaid interest to zero (all accrued interest has been cleared)
        position.interestRepaid = 0;
        // reset last repay time to now
        position.lastRepaidTime = block.timestamp;
      }
    }

    // post repayment
    if (position.principalRepaid >= position.principal) {
      // removes it from user's fixed positions
      _removeFixedPositionByPosId(onBehalf, posId);
    } else {
      // update position
      _updateFixedPosition(onBehalf, position);
    }

    // validate positions
    _validatePositions(onBehalf);

    // emit event
    emit RepaidFixedLoanPosition(
      onBehalf,
      posId,
      position.principal,
      position.start,
      position.end,
      position.apr,
      position.principalRepaid,
      position.principalRepaid >= position.principal
    );
  }

  /**
   * @dev Convert a portion of or the entire dynamic loan position to a fixed loan position
   * @param amount The amount to convert from dynamic to fixed
   * @param termId The ID of the fixed term to use
   */
  function convertDynamicToFixed(
    uint256 amount,
    uint256 termId
  ) external override marketIdSet whenBorrowNotPaused whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    address user = msg.sender;
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    require(fixedLoanPositions[user].length < maxFixedLoanPositions, "broker/exceed-max-fixed-positions");
    // cap amount by principal
    amount = UtilsLib.min(amount, position.principal);
    // accrue current rate so normalized debt reflects the latest interest
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    uint256 totalInterest = actualDebt.zeroFloorSub(position.principal);

    // force user to repay interest portion when converting to fixed
    uint256 interestToRepay = BrokerMath.mulDivCeiling(amount, totalInterest, position.principal);
    if (interestToRepay > 0) {
      // borrow from Moolah to increase user's actual debt at moolah
      _borrowFromMoolah(user, interestToRepay);
      // supply interest to moolah vault as revenue
      _supplyToMoolahVault(interestToRepay);
    }

    position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
      BrokerMath.normalizeBorrowAmount(amount, rate, false)
    );
    position.principal -= amount;

    if (position.principal == 0) {
      delete dynamicLoanPositions[user];
    }

    FixedTermAndRate memory term = _getTermById(termId);
    uint256 start = block.timestamp;
    uint256 end = start + term.duration;
    // pos uuid increment
    fixedPosUuid++;
    // create new fixed position
    fixedLoanPositions[user].push(
      FixedLoanPosition({
        posId: fixedPosUuid,
        principal: amount,
        apr: term.apr,
        start: start,
        end: end,
        lastRepaidTime: start,
        interestRepaid: 0,
        principalRepaid: 0
      })
    );

    // validate positions
    _validatePositions(user);

    emit FixedLoanPositionCreated(user, fixedPosUuid, amount, start, end, term.apr, termId);
  }

  ///////////////////////////////////////
  /////         Liquidation         /////
  ///////////////////////////////////////
  /**
   * @dev Liquidate a borrower's debt by accruing interest and repaying the dynamic
   *      position first, then settling fixed-rate positions sorted by APR and
   *      remaining principal. The last fixed position absorbs any rounding delta.
   *      the parameters are the same as normal liquidator calls moolah.liquidate()
   * @notice liquidator needs to calculate the extra amount need to repay the interest at broker side
   *         approve extra amount to broker before calling liquidate
   * @param marketParams The market of the position.
   * @param borrower The owner of the position.
   * @param seizedAssets The amount of collateral to seize.
   * @param repaidShares The amount of shares to repay.
   * @param data Arbitrary data to pass to the `onMoolahLiquidate` callback. Pass empty data if not needed.
   */
  function liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
  ) external override marketIdSet whenNotPaused nonReentrant {
    Id id = marketParams.id();
    require(_checkLiquidationWhiteList(msg.sender), "broker/not-liquidation-whitelist");
    require(Id.unwrap(id) == Id.unwrap(MARKET_ID), "broker/invalid-market-id");
    require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), "broker/invalid-liquidation-params");
    require(borrower != address(0), "broker/invalid-user");
    // fetch positions
    DynamicLoanPosition storage dynamicPosition = dynamicLoanPositions[borrower];
    FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[borrower];
    Market memory market = MOOLAH.market(id);
    // [1] calculate total outstanding debt before liquidation (principal + interest)
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    uint256 totalDebtAtBroker = BrokerMath.getTotalDebt(fixedPositions, dynamicPosition, rate);
    // [2] calculate actual debt at Moolah after liquidation
    uint256 debtAtMoolah = BrokerMath.getDebtAtMoolah(borrower);

    // [3] calculate the loan token amount to repay to moolah
    uint256 repaidAssets;
    (, , repaidAssets) = BrokerMath.previewLiquidationRepayment(
      marketParams,
      market,
      seizedAssets,
      repaidShares,
      MOOLAH._getPrice(marketParams, borrower)
    );

    // [4] calculate extra amount we need to repay interest to broker
    uint256 interestToBroker = BrokerMath.mulDivCeiling(repaidAssets, totalDebtAtBroker, debtAtMoolah).zeroFloorSub(
      repaidAssets
    );

    // [5] transfer loan token from liquidator and supply interest to vault
    IERC20(LOAN_TOKEN).safeTransferFrom(msg.sender, address(this), repaidAssets + interestToBroker);
    if (interestToBroker > 0) {
      _supplyToMoolahVault(interestToBroker);
    }

    // [6] init liquidation context for onMoolahLiquidate() Callback
    uint256 collateralTokenPrebalance = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
    liquidationContext = LiquidationContext({
      active: true,
      liquidator: msg.sender,
      preCollateral: collateralTokenPrebalance
    });

    // [7] call liquidate on moolah
    IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), repaidAssets);
    MOOLAH.liquidate(marketParams, borrower, seizedAssets, repaidShares, data);

    // [8] send seized collateral to liquidator or call back if data is provided
    if (data.length == 0) {
      // if no data provided, transfer seized collateral to liquidator directly
      IERC20(COLLATERAL_TOKEN).safeTransfer(
        msg.sender,
        IERC20(COLLATERAL_TOKEN).balanceOf(address(this)) - collateralTokenPrebalance
      );
    }

    // must clear liquidation context after liquidation
    delete liquidationContext;

    // [8] edge case: bad debt/full liquidation so that borrow share debt is zero
    if (BrokerMath.getDebtAtMoolah(borrower) == 0) {
      // clear all positions
      delete dynamicLoanPositions[borrower];
      delete fixedLoanPositions[borrower];
    } else {
      // [9] deduct interest and principal from positions
      // deduct from dynamic position and returns the leftover assets to deduct
      (uint256 interestLeftover, uint256 principalLeftover) = _deductDynamicPositionDebt(
        borrower,
        dynamicPosition,
        interestToBroker,
        repaidAssets,
        rate
      );
      // deduct from fixed positions
      if ((principalLeftover > 0 || interestLeftover > 0) && fixedPositions.length > 0) {
        // sort fixed positions from earliest end time to latest, filter out fully repaid positions
        // positions with earlier end time will be deducted first
        FixedLoanPosition[] memory sorted = BrokerMath.sortAndFilterFixedPositions(fixedPositions);
        if (sorted.length > 0) {
          _deductFixedPositionsDebt(borrower, sorted, interestLeftover, principalLeftover);
        }
      }
    }

    // emit event
    emit Liquidated(borrower, totalDebtAtBroker.zeroFloorSub(debtAtMoolah));
  }

  /**
   * @dev callback function called by Moolah after liquidation
   * @param repaidAssets The amount of assets repaid to Moolah
   * @param data Additional data passed from the liquidator
   */
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external onlyMoolah marketIdSet {
    address liquidator = liquidationContext.liquidator;
    if (liquidationContext.active && liquidator != address(0)) {
      // transfer seized collateral to liquidator
      IERC20(COLLATERAL_TOKEN).safeTransfer(
        liquidator,
        IERC20(COLLATERAL_TOKEN).balanceOf(address(this)) - liquidationContext.preCollateral
      );
      // call back to liquidator if data is provided
      IMoolahLiquidateCallback(liquidator).onMoolahLiquidate(repaidAssets, data);
    }
  }

  /**
   * @dev check if the liquidator is in the whitelist
   * @param liquidator The address of the liquidator
   */
  function _checkLiquidationWhiteList(address liquidator) internal view returns (bool) {
    if (liquidationWhitelist.length() == 0) {
      return true;
    }
    return liquidationWhitelist.contains(liquidator);
  }

  /**
   * @dev deducts debt from the dynamic position and returns leftover assets
   * @param position The dynamic loan position to modify
   * @param interestToDeduct The amount of interest repaid during liquidation, leads to deduct from principal and interest
   * @param principalToDeduct The amount of assets repaid during liquidation, leads to deduct from principal and interest
   * @param rate The current interest rate
   */
  function _deductDynamicPositionDebt(
    address user,
    DynamicLoanPosition memory position,
    uint256 interestToDeduct,
    uint256 principalToDeduct,
    uint256 rate
  ) internal returns (uint256, uint256) {
    // call BrokerMath to process deduction
    // will return leftover interest/principal to deduct and the updated position
    (interestToDeduct, principalToDeduct, position) = BrokerMath.deductDynamicPositionDebt(
      position,
      interestToDeduct,
      principalToDeduct,
      rate
    );
    // update position
    dynamicLoanPositions[user] = position;
    return (interestToDeduct, principalToDeduct);
  }

  /**
   * @dev allocates repayments to fixed positions by APR and remaining principal
   * @param user The address of the user
   * @param sortedFixedPositions The sorted fixed loan positions
   * @param interestToDeduct The amount of interest repaid during liquidation, leads to deduct from principal and interest
   * @param principalToDeduct The amount of assets repaid during liquidation, leads to deduct from principal and interest
   */
  function _deductFixedPositionsDebt(
    address user,
    FixedLoanPosition[] memory sortedFixedPositions,
    uint256 interestToDeduct,
    uint256 principalToDeduct
  ) internal {
    uint256 len = sortedFixedPositions.length;
    for (uint256 i = 0; i < len; i++) {
      if (principalToDeduct == 0) break;
      FixedLoanPosition memory p = sortedFixedPositions[i];
      // call BrokerMath to process deduction one by one
      // will return leftover interest/principal to deduct and the updated position
      (interestToDeduct, principalToDeduct, p) = BrokerMath.deductFixedPositionDebt(
        interestToDeduct,
        principalToDeduct,
        p
      );
      // post repayment
      if (p.principalRepaid >= p.principal) {
        // removes it from user's fixed positions
        _removeFixedPositionByPosId(user, p.posId);
      } else {
        // update position
        _updateFixedPosition(user, p);
      }
    }
  }

  ///////////////////////////////////////
  /////        View functions       /////
  ///////////////////////////////////////

  /**
   * @dev returns all fixed terms and rates products
   */
  function getFixedTerms() external view override returns (FixedTermAndRate[] memory) {
    return fixedTerms;
  }

  /**
   * @dev IOracle-compatible peek for base prices (no user context)
   *      essential for Moolah to init the market
   * @param asset The token to fetch the price for
   * @return price Price with 8 decimals, proxied from the underlying oracle
   */
  function peek(address asset) external view returns (uint256 price) {
    return IOracle(ORACLE).peek(asset);
  }

  /**
   * @dev returns the price of a token for a user in 8 decimal places
   * @param token The address of the token to get the price for
   * @param user The address of the user
   */
  function peek(address token, address user) public view override marketIdSet returns (uint256 price) {
    require(user != address(0), "broker/zero-address");
    require(token == COLLATERAL_TOKEN || token == LOAN_TOKEN, "broker/unsupported-token");
    price = BrokerMath.peek(token, user, address(MOOLAH), rateCalculator, address(ORACLE));
  }

  /**
   * @dev Get all fixed loan positions of a user
   * @param user The address of the user
   * @return An array of FixedLoanPosition structs
   */
  function userFixedPositions(address user) external view override returns (FixedLoanPosition[] memory) {
    return fixedLoanPositions[user];
  }

  /**
   * @dev Get the dynamic loan position of a user
   * @param user The address of the user
   * @return The DynamicLoanPosition struct
   */
  function userDynamicPosition(address user) external view override returns (DynamicLoanPosition memory) {
    return dynamicLoanPositions[user];
  }

  /**
   * @dev Preview the interest, penalty and principal repaid
   * @notice for frontend usage, when user is repaying a fixed loan position with certain amount
   * @param user The address of the user
   * @param amount The amount to repay
   * @param posId The ID of the fixed position to repay
   * @return interestRepaid The interest portion of the repayment
   * @return penalty The penalty portion of the repayment
   * @return principalRepaid The principal portion of the repayment
   */
  function previewRepayFixedLoanPosition(
    address user,
    uint256 amount,
    uint256 posId
  ) external view returns (uint256 interestRepaid, uint256 penalty, uint256 principalRepaid) {
    require(amount > 0, "broker/zero-amount");
    require(user != address(0), "broker/zero-address");
    FixedLoanPosition memory position = _getFixedPositionByPosId(user, posId);
    (interestRepaid, penalty, principalRepaid) = BrokerMath.previewRepayFixedLoanPosition(position, amount);
  }

  /**
   * @dev Get the liquidation whitelist
   * @return An array of addresses in the liquidation whitelist
   */
  function getLiquidationWhitelist() external view returns (address[] memory) {
    address[] memory whitelist = new address[](liquidationWhitelist.length());
    for (uint256 i = 0; i < liquidationWhitelist.length(); i++) {
      whitelist[i] = liquidationWhitelist.at(i);
    }
    return whitelist;
  }

  ///////////////////////////////////////
  /////        Bot functions        /////
  ///////////////////////////////////////

  /**
   * @dev convert matured fixed positions to dynamic position
   * @notice Before the fixed position is qualified to convert to dynamic position
   *         there will be a tiny time interval awaiting for the bot to trigger the conversion
   *         interest should be accrued during this interval will be ignored
   * @param user The address of the user
   * @param posIds The posIds of the positions to refinance
   */
  function refinanceMaturedFixedPositions(
    address user,
    uint256[] calldata posIds
  ) external override whenNotPaused nonReentrant marketIdSet onlyRole(BOT) {
    require(posIds.length > 0, "Broker/zero-positions");
    // update rate
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    // get refinanced positions and updated dynamic position
    (
      FixedLoanPosition[] memory updatedFixedPos,
      DynamicLoanPosition memory updatedDynPos,
      uint256 refinancedPrincipal
    ) = BrokerMath.refinanceMaturedFixedPositions(user, rate, posIds);
    // update fixed positions
    fixedLoanPositions[user] = updatedFixedPos;
    // update dynamic position if changed
    if (refinancedPrincipal > 0) {
      dynamicLoanPositions[user] = updatedDynPos;
      emit DynamicLoanPositionBorrowed(user, refinancedPrincipal, updatedDynPos.principal);
    }
  }

  ///////////////////////////////////////
  /////      Internal functions     /////
  ///////////////////////////////////////

  /**
   * @dev Get the market parameters for this broker
   */
  function _getMarketParams(Id _id) internal view returns (MarketParams memory) {
    return MOOLAH.idToMarketParams(_id);
  }

  /**
   * @dev Get the fixed term by ID
   * @notice this will only be called when user borrows with fixed term
   *         and number of fixed-term products is very limited
   *         so we can ignore the gas-consumption here
   * @param termId The ID of the term to retrieve
   * @return The fixed term and rate scheme
   */
  function _getTermById(uint256 termId) internal view returns (FixedTermAndRate memory) {
    for (uint256 i = 0; i < fixedTerms.length; i++) {
      if (fixedTerms[i].termId == termId) {
        return fixedTerms[i];
      }
    }
    revert("broker/term-not-found");
  }

  /**
   * @dev Borrow an amount on behalf of a user from Moolah
   * @param onBehalf The address of the user to borrow on behalf of
   * @param amount The amount to borrow
   */
  function _borrowFromMoolah(address onBehalf, uint256 amount) internal {
    MarketParams memory marketParams = _getMarketParams(MARKET_ID);
    // pre-balance
    uint256 preBalance = IERC20(LOAN_TOKEN).balanceOf(address(this));
    // borrow from moolah with zero interest
    MOOLAH.borrow(marketParams, amount, 0, onBehalf, address(this));
    // should increase the loan balance same as borrowed amount
    require(IERC20(LOAN_TOKEN).balanceOf(address(this)) - preBalance == amount, "broker/invalid-borrowed-amount");
  }

  /**
   * @dev Repay an amount on behalf of a user to Moolah
   * @param payer The address of the user who pays for the repayment
   * @param onBehalf The address of the user to repay on behalf of
   * @param amount The amount to repay
   */
  function _repayToMoolah(address payer, address onBehalf, uint256 amount) internal returns (uint256 assetsRepaid) {
    IERC20(LOAN_TOKEN).safeTransferFrom(payer, address(this), amount);
    IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), amount);

    Market memory market = MOOLAH.market(MARKET_ID);
    // convert amount to shares
    uint256 amountShares = amount.toSharesDown(market.totalBorrowAssets, market.totalBorrowShares);
    // using `shares` to ensure full repayment
    (assetsRepaid /* sharesRepaid */, ) = MOOLAH.repay(_getMarketParams(MARKET_ID), 0, amountShares, onBehalf, "");
    // refund any excess amount to payer
    if (amount > assetsRepaid) {
      IERC20(LOAN_TOKEN).safeTransfer(payer, amount - assetsRepaid);
    }
  }

  /**
   * @dev Supply an amount of interest to Moolah
   * @param interest The amount of interest to supply
   */
  function _supplyToMoolahVault(uint256 interest) internal {
    if (interest > 0) {
      // approve to relayer
      IERC20(LOAN_TOKEN).safeIncreaseAllowance(RELAYER, interest);
      // supply interest to relayer to be deposited into vault
      IBrokerInterestRelayer(RELAYER).supplyToVault(interest);
    }
  }

  /**
   * @dev removes a user's fixed-loan position at a specific index
   * @param user The address of the user
   * @param posId The ID of the position to remove
   */
  function _removeFixedPositionByPosId(address user, uint256 posId) internal {
    // get user's fixed positions
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    // loop through user's positions
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        // remove position
        positions[i] = positions[positions.length - 1];
        positions.pop();
        emit FixedLoanPositionRemoved(user, posId);
        return;
      }
    }
    revert("broker/position-not-found");
  }

  /**
   * @dev Get a fixed loan position by PosId
   * @param user The address of the user
   * @param posId The ID of the position to get
   */
  function _getFixedPositionByPosId(address user, uint256 posId) internal view returns (FixedLoanPosition memory) {
    FixedLoanPosition[] memory positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        return positions[i];
      }
    }
    revert("broker/position-not-found");
  }

  /**
   * @dev Update a fixed loan position
   * @param user The address of the user
   * @param position The fixed loan position to update
   */
  function _updateFixedPosition(address user, FixedLoanPosition memory position) internal {
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == position.posId) {
        positions[i] = position;
        return;
      }
    }
    revert("broker/position-not-found");
  }

  /**
   * @dev Get the interest for a fixed loan position
   * @param position The fixed loan position to get the interest for
   */
  function _getAccruedInterestForFixedPosition(FixedLoanPosition memory position) internal view returns (uint256) {
    return BrokerMath.getAccruedInterestForFixedPosition(position);
  }

  /**
   * @dev Get the penalty for a fixed loan position
   * @param position The fixed loan position to get the penalty for
   * @param repayAmt The actual repay amount (repay amount excluded accrued interest)
   */
  function _getPenaltyForFixedPosition(
    FixedLoanPosition memory position,
    uint256 repayAmt
  ) internal view returns (uint256 penalty) {
    return BrokerMath.getPenaltyForFixedPosition(position, repayAmt);
  }

  /**
   * @dev Validate that the user's positions meet the minimum loan requirement
   * @param user The address of the user
   */
  function _validatePositions(address user) internal view {
    require(
      BrokerMath.checkPositionsMeetsMinLoan(user, address(MOOLAH), rateCalculator),
      "broker/positions-below-min-loan"
    );
  }

  ///////////////////////////////////////
  /////       Admin functions       /////
  ///////////////////////////////////////

  /**
   * @dev Set the market ID for the broker
   * @param marketId The market ID
   */
  function setMarketId(Id marketId) external onlyRole(MANAGER) {
    // can only be set once
    require(Id.unwrap(MARKET_ID) == bytes32(0), "broker/invalid-market");
    MARKET_ID = marketId;
    MarketParams memory _marketParams = MOOLAH.idToMarketParams(marketId);
    LOAN_TOKEN = _marketParams.loanToken;
    COLLATERAL_TOKEN = _marketParams.collateralToken;
    // set broker name
    string memory collateralTokenName = IERC20Metadata(COLLATERAL_TOKEN).symbol();
    string memory loanTokenName = IERC20Metadata(LOAN_TOKEN).symbol();
    BROKER_NAME = string(abi.encodePacked("Lista-Lending ", collateralTokenName, "-", loanTokenName, " Broker"));
    // emit event
    emit MarketIdSet(marketId);
  }

  /**
   * @dev Add, update or remove a fixed term and rate for borrowing
   * @param term The fixed term and rate scheme
   * @param removeTerm True to remove the term, false to add or update
   */
  function updateFixedTermAndRate(FixedTermAndRate calldata term, bool removeTerm) external onlyRole(MANAGER) {
    require(term.termId > 0, "broker/invalid-term-id");
    require(term.duration > 0, "broker/invalid-duration");
    require(term.apr >= RATE_SCALE, "broker/invalid-apr");
    // update term if it exists
    for (uint256 i = 0; i < fixedTerms.length; i++) {
      // term found
      if (fixedTerms[i].termId == term.termId) {
        // remove term
        if (removeTerm) {
          fixedTerms[i] = fixedTerms[fixedTerms.length - 1];
          fixedTerms.pop();
        } else {
          fixedTerms[i] = term;
          emit FixedTermAndRateUpdated(term.termId, term.duration, term.apr);
        }
        return;
      }
    }
    // item not found
    // adding new term
    if (!removeTerm) {
      fixedTerms.push(term);
    } else {
      revert("broker/term-not-found");
    }
  }

  /**
   * @dev Set the maximum number of fixed loan positions a user can have
   * @param maxPositions The new maximum number of fixed loan positions
   */
  function setMaxFixedLoanPositions(uint256 maxPositions) external onlyRole(MANAGER) {
    require(maxFixedLoanPositions != maxPositions, "broker/same-value-provided");
    emit MaxFixedLoanPositionsUpdated(maxFixedLoanPositions, maxPositions);
    maxFixedLoanPositions = maxPositions;
  }

  /**
   * @dev Pause or unpause the borrow function
   * @param paused True to pause, false to unpause
   */
  function setBorrowPaused(bool paused) external onlyRole(MANAGER) {
    require(borrowPaused != paused, "broker/same-value-provided");
    borrowPaused = paused;
    emit BorrowPaused(paused);
  }

  /**
   * @dev pause contract
   */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /**
   * @dev unpause contract
   */
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /**
   * @dev add an address to the liquidation whitelist
   * @param account The address to add
   */
  function toggleLiquidationWhitelist(address account, bool isAddition) public onlyRole(MANAGER) {
    require(isAddition != liquidationWhitelist.contains(account), "broker/same-value-provided");
    if (isAddition) {
      liquidationWhitelist.add(account);
      emit AddedLiquidationWhitelist(account);
    } else {
      liquidationWhitelist.remove(account);
      emit RemovedLiquidationWhitelist(account);
    }
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

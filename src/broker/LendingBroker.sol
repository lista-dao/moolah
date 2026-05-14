// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
import { LendingBrokerOperatorLib } from "./libraries/LendingBrokerOperatorLib.sol";
import { IBrokerInterestRelayer } from "./interfaces/IBrokerInterestRelayer.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { IMoolahLiquidateCallback } from "../moolah/interfaces/IMoolahCallbacks.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";
import { IWBNB } from "../provider/interfaces/IWBNB.sol";

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

  // ------- Custom Errors -------
  error ZeroAmount();
  error NativeNotSupported();
  error ZeroAddress();
  error NothingToRepay();
  error ExceedMaxFixedPositions();
  error NotLiquidationWhitelist();
  error InvalidMarketId();
  error InvalidUser();
  error UnsupportedToken();
  error ZeroPositions();
  error InvalidBorrowedAmount();
  error InsufficientAmount();
  error NativeTransferFailed();
  error InvalidMarket();
  error InvalidTermId();
  error InvalidDuration();
  error InvalidAPR();
  error SameValueProvided();
  error TermNotFound();
  error PositionNotFound();
  error NotAuthorized();
  error NotMoolah();
  error MarketNotSet();
  error BorrowIsPaused();
  error InvalidRepaidShares();

  // ------- Roles -------
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");

  // ------- Immutables -------
  IMoolah public immutable MOOLAH;
  /// @dev Wrapped native token (e.g. WBNB). address(0) if native borrow/repay is not supported.
  address public immutable WBNB;
  uint256 public constant MAX_FIXED_TERM_APR = 13e26; // 1.3 * RATE_SCALE = 30% MAX APR
  uint256 public constant MIN_FIXED_TERM_APR = 101 * 1e25; // 0.01 * RATE_SCALE = 1% MIN APR

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

  // --- V2 storage (appended to preserve layout) ---
  address public RELAYER;
  IOracle public ORACLE;

  // ------- Modifiers -------
  modifier onlyMoolah() {
    if (msg.sender != address(MOOLAH)) revert NotMoolah();
    _;
  }

  modifier marketIdSet() {
    if (Id.unwrap(MARKET_ID) == bytes32(0)) revert MarketNotSet();
    _;
  }

  modifier whenBorrowNotPaused() {
    if (borrowPaused) revert BorrowIsPaused();
    _;
  }

  /**
   * @dev Constructor for the LendingBroker contract
   * @param moolah The address of the Moolah contract
   * @param wbnb The address of the wrapped native token (e.g. WBNB). Pass address(0) to disable native support.
   */
  constructor(address moolah, address wbnb) {
    if (moolah == address(0)) revert ZeroAddress();
    MOOLAH = IMoolah(moolah);
    WBNB = wbnb;
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
   * @param _relayer The address of the BrokerInterestRelayer contract
   * @param _oracle The address of the oracle
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address _rateCalculator,
    uint256 _maxFixedLoanPositions,
    address _relayer,
    address _oracle
  ) public initializer {
    if (
      _admin == address(0) ||
      _manager == address(0) ||
      _bot == address(0) ||
      _pauser == address(0) ||
      _rateCalculator == address(0) ||
      _maxFixedLoanPositions == 0 ||
      _relayer == address(0) ||
      _oracle == address(0)
    ) revert ZeroAddress();

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
    RELAYER = _relayer;
    ORACLE = IOracle(_oracle);
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Borrow a fixed amount of loan token with a dynamic rate
   * @param amount The amount to borrow
   */
  function borrow(uint256 amount) external override marketIdSet whenNotPaused whenBorrowNotPaused nonReentrant {
    if (amount == 0) revert ZeroAmount();
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
    _transferLoanToken(payable(user), amount);
    // validate the modified dynamic position
    _validateDynamicPosition(user);
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
    if (amount == 0) revert ZeroAmount();
    address user = msg.sender;
    _borrowFixed(user, amount, termId);
    // transfer loan token to user (unwraps to native BNB if supported)
    _transferLoanToken(payable(user), amount);
  }

  /**
   * @dev Repay a Dynamic loan position
   * @param amount The amount to repay (overridden by msg.value when sending native BNB)
   * @param onBehalf The address of the user whose position to repay
   */
  function repay(uint256 amount, address onBehalf) external payable override marketIdSet whenNotPaused nonReentrant {
    LendingBrokerOperatorLib.repayDynamic(dynamicLoanPositions, _operatorCtx(), amount, onBehalf);
  }

  /**
   * @dev Repay a Fixed loan position
   * @notice repay interest first then principal, repay amount must larger than interest
   * @param amount The amount to repay (overridden by msg.value when sending native BNB)
   * @param posId The ID of the fixed position to repay
   * @param onBehalf The address of the user whose position to repay
   */
  function repay(
    uint256 amount,
    uint256 posId,
    address onBehalf
  ) external payable override marketIdSet whenNotPaused nonReentrant {
    LendingBrokerOperatorLib.repayFixed(fixedLoanPositions, _operatorCtx(), amount, posId, onBehalf);
  }

  /**
   * @dev Emergency: fully repay every position (dynamic + all fixed) of `onBehalf` in one call.
   *      Charges full early-repay penalty on fixed positions, identical to normal `repay`.
   *      Skips per-position validation since every position is cleared.
   * @notice For native BNB, send `msg.value >= totalDebt`; excess is refunded.
   *         For ERC20, the contract pulls exactly `totalDebt` from `msg.sender`.
   * @param onBehalf The address of the user whose positions to repay
   */
  function repayAll(address onBehalf) external payable override marketIdSet whenNotPaused nonReentrant {
    LendingBrokerOperatorLib.repayAll(dynamicLoanPositions, fixedLoanPositions, _operatorCtx(), onBehalf);
  }

  /// @dev Build the operator-library context. Internal helper, inlined.
  function _operatorCtx() private view returns (LendingBrokerOperatorLib.OperatorContext memory) {
    return
      LendingBrokerOperatorLib.OperatorContext({
        moolah: MOOLAH,
        loanToken: LOAN_TOKEN,
        wbnb: WBNB,
        rateCalculator: rateCalculator,
        relayer: RELAYER,
        marketId: MARKET_ID
      });
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
    if (amount == 0) revert ZeroAmount();
    address user = msg.sender;
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    // accrue current rate so normalized debt reflects the latest interest
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    (uint256 interestToRepay, uint256 principalToMove, uint256 finalAmount) = BrokerMath.previewConvertDynamicToFixed(
      position,
      amount,
      rate
    );
    if (finalAmount == 0) revert ZeroAmount();

    if (interestToRepay > 0) {
      // borrow from Moolah to increase user's actual debt at moolah
      _borrowFromMoolah(user, interestToRepay);
      // supply interest to moolah vault as revenue
      _supplyToMoolahVault(interestToRepay);
    }

    position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
      BrokerMath.normalizeBorrowAmount(finalAmount, rate, false)
    );
    position.principal -= principalToMove;

    if (position.principal == 0) {
      delete dynamicLoanPositions[user];
    }

    _validateDynamicPosition(user);
    _createFixedPosition(user, finalAmount, termId);
  }

  /**
   * @dev Borrow with a fixed rate and term on behalf of a user.
   *      Caller must be authorized in Moolah (MOOLAH.isAuthorized(user, msg.sender)).
   *      Borrowed tokens are sent to `receiver` instead of `user`.
   * @param amount The amount to borrow
   * @param termId The ID of the fixed term to use
   * @param user The address of the user whose position is created
   * @param receiver The address that receives the borrowed tokens
   */
  function borrow(
    uint256 amount,
    uint256 termId,
    address user,
    address receiver
  ) external marketIdSet whenNotPaused whenBorrowNotPaused nonReentrant {
    if (amount == 0) revert ZeroAmount();
    if (receiver == address(0)) revert ZeroAddress();
    if (!MOOLAH.isAuthorized(user, msg.sender)) revert NotAuthorized();
    _borrowFixed(user, amount, termId);
    // Moolah requires receiver == broker when a broker is registered;
    // tokens land here via _borrowFixed, then forwarded to receiver (always ERC20, never native)
    IERC20(LOAN_TOKEN).safeTransfer(receiver, amount);
  }

  /// @dev Accept native BNB sent back by WBNB.withdraw()
  receive() external payable {}

  ///////////////////////////////////////
  /////         Liquidation         /////
  ///////////////////////////////////////
  /**
   * @dev Liquidate a borrower's debt by accruing interest and repaying the dynamic
   *      position first, then settling fixed-rate positions in order of earliest end
   *      time first. The last fixed position absorbs any rounding delta.
   *      the parameters are the same as normal liquidator calls moolah.liquidate()
   * @notice Only contracts whitelisted via `toggleLiquidationWhitelist` (e.g. `BrokerLiquidator.sol`) can call this function
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
    if (!_checkLiquidationWhiteList(msg.sender)) revert NotLiquidationWhitelist();
    if (Id.unwrap(id) != Id.unwrap(MARKET_ID)) revert InvalidMarketId();
    if (!UtilsLib.exactlyOneZero(seizedAssets, repaidShares)) revert InvalidMarketId();
    if (repaidShares > 0 && repaidShares % SharesMathLib.VIRTUAL_SHARES != 0) revert InvalidRepaidShares();
    if (borrower == address(0)) revert InvalidUser();

    // [1] init liquidation context for onMoolahLiquidate() Callback
    uint256 collateralTokenPrebalance = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
    liquidationContext = LiquidationContext({
      active: true,
      liquidator: msg.sender,
      interestToBroker: 0,
      borrower: borrower,
      debtAtMoolah: BrokerMath.getDebtAtMoolah(borrower),
      preCollateral: collateralTokenPrebalance
    });

    // [2] call liquidate on moolah (then onMoolahLiquidate will be called back)
    uint256 repaidAssets;
    (, repaidAssets) = MOOLAH.liquidate(marketParams, borrower, seizedAssets, repaidShares, data);

    // [11] supply interest to moolah vault
    uint256 interestToBroker = liquidationContext.interestToBroker;
    if (interestToBroker > 0) {
      _supplyToMoolahVault(interestToBroker);
    }

    // [12] must clear liquidation context after liquidation
    delete liquidationContext;

    // emit event
    emit Liquidated(borrower, repaidAssets, interestToBroker);
  }

  /**
   * @dev callback function called by Moolah after liquidation
   * @param repaidAssets The amount of assets repaid to Moolah
   * @param data Additional data passed from the liquidator
   */
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external onlyMoolah marketIdSet {
    address liquidator = liquidationContext.liquidator;
    address borrower = liquidationContext.borrower;
    if (liquidationContext.active && liquidator != address(0)) {
      // fetch positions
      DynamicLoanPosition storage dynamicPosition = dynamicLoanPositions[borrower];
      FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[borrower];

      // [3] transfer seized collateral to liquidator
      IERC20(COLLATERAL_TOKEN).safeTransfer(
        liquidator,
        IERC20(COLLATERAL_TOKEN).balanceOf(address(this)) - liquidationContext.preCollateral
      );
      // approve repaid assets to moolah
      IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), repaidAssets);

      // [4] calculate interest to broker
      uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
      uint256 totalDebtAtBroker = BrokerMath.getTotalDebt(fixedPositions, dynamicPosition, rate);
      uint256 interestToBroker = BrokerMath
        .mulDivCeiling(repaidAssets, totalDebtAtBroker, liquidationContext.debtAtMoolah)
        .zeroFloorSub(repaidAssets);

      // [5] call back to liquidator (let Liquidator approve extra amount)
      IMoolahLiquidateCallback(liquidator).onMoolahLiquidate(repaidAssets + interestToBroker, data);
      // save interest to context
      // supply to vault will be done after moolah.liqudate() to prevent reentrancy
      liquidationContext.interestToBroker = interestToBroker;

      // [6] transfer loan token we needed from liquidator
      IERC20(LOAN_TOKEN).safeTransferFrom(liquidator, address(this), repaidAssets + interestToBroker);

      // [8] edge case: bad debt/full liquidation so that borrow share debt is zero
      if (BrokerMath.getDebtAtMoolah(borrower) == 0) {
        // clear all positions
        delete dynamicLoanPositions[borrower];
        delete fixedLoanPositions[borrower];
      } else {
        // [9] run the full cascade in one library call: deduct from the dynamic
        // position, sort the fixed positions, then deduct from them in order
        (
          DynamicLoanPosition memory updatedDyn,
          FixedLoanPosition[] memory touched,
          bool[] memory shouldRemove
        ) = BrokerMath.executeLiquidationCascade(dynamicPosition, fixedPositions, interestToBroker, repaidAssets, rate);
        // apply dynamic update
        dynamicLoanPositions[borrower] = updatedDyn;
        // apply fixed-position updates
        for (uint256 i = 0; i < touched.length; i++) {
          if (shouldRemove[i]) {
            _removeFixedPositionByPosId(borrower, touched[i].posId);
          } else {
            _updateFixedPosition(borrower, touched[i]);
          }
        }
      }
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
    if (user == address(0)) revert ZeroAddress();
    if (token != COLLATERAL_TOKEN && token != LOAN_TOKEN) revert UnsupportedToken();
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
   * @dev Get the total debt of a user (dynamic + fixed)
   * @param user The address of the user
   */
  function getUserTotalDebt(address user) external view override returns (uint256 totalDebt) {
    uint256 rate = IRateCalculator(rateCalculator).getRate(address(this));
    DynamicLoanPosition memory dynPos = dynamicLoanPositions[user];
    FixedLoanPosition[] memory fixedPos = fixedLoanPositions[user];
    totalDebt = BrokerMath.getTotalDebt(fixedPos, dynPos, rate);
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
    if (amount == 0) revert ZeroAmount();
    if (user == address(0)) revert ZeroAddress();
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
    if (posIds.length == 0) revert ZeroPositions();
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
   * @dev Create a fixed-term borrow position for `user`, borrow from Moolah, validate, and emit.
   *      Tokens land in this contract; caller is responsible for forwarding them to the recipient.
   * @param user The borrower whose position is created
   * @param amount The borrow amount
   * @param termId The fixed-term product ID
   */
  function _borrowFixed(address user, uint256 amount, uint256 termId) private {
    _createFixedPosition(user, amount, termId);
    _borrowFromMoolah(user, amount);
  }

  /**
   * @dev Create and push a new fixed-term position for `user`. Used by both `_borrowFixed`
   *      (fresh fixed borrow) and `convertDynamicToFixed` (moves principal/interest from
   *      a dynamic position). Validates the new position before returning.
   * @param user The user the position belongs to
   * @param amount The position's principal
   * @param termId The fixed-term product ID
   */
  function _createFixedPosition(address user, uint256 amount, uint256 termId) private {
    if (fixedLoanPositions[user].length >= maxFixedLoanPositions) revert ExceedMaxFixedPositions();
    FixedTermAndRate memory term = _getTermById(termId);
    uint256 start = block.timestamp;
    uint256 end = start + term.duration;
    fixedPosUuid++;
    FixedLoanPosition memory newPos = FixedLoanPosition({
      posId: fixedPosUuid,
      principal: amount,
      apr: term.apr,
      start: start,
      end: end,
      lastRepaidTime: start,
      interestRepaid: 0,
      principalRepaid: 0
    });
    fixedLoanPositions[user].push(newPos);
    _validateFixedPosition(newPos);
    emit FixedLoanPositionCreated(user, fixedPosUuid, amount, start, end, term.apr, termId);
  }

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
    revert TermNotFound();
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
    if (IERC20(LOAN_TOKEN).balanceOf(address(this)) - preBalance != amount) revert InvalidBorrowedAmount();
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
    revert PositionNotFound();
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
    revert PositionNotFound();
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
    revert PositionNotFound();
  }

  /**
   * @dev Transfer loan token to recipient. Unwraps to native BNB when supported.
   */
  function _transferLoanToken(address payable recipient, uint256 amount) internal {
    if (LOAN_TOKEN == WBNB && MOOLAH.providers(MARKET_ID, WBNB) != address(0)) {
      _unwrapAndSend(recipient, amount);
    } else {
      IERC20(LOAN_TOKEN).safeTransfer(recipient, amount);
    }
  }

  /**
   * @dev Unwrap WBNB and send native BNB to recipient.
   */
  function _unwrapAndSend(address payable recipient, uint256 amount) internal {
    IWBNB(WBNB).withdraw(amount);
    (bool ok, ) = recipient.call{ value: amount }("");
    if (!ok) revert NativeTransferFailed();
  }

  /**
   * @dev Validate that the user's dynamic position is either zero or meets the minimum loan
   * @param user The address of the user
   */
  function _validateDynamicPosition(address user) internal view {
    uint256 principal = dynamicLoanPositions[user].principal;
    if (principal == 0) return;
    uint256 minLoan = MOOLAH.minLoan(_getMarketParams(MARKET_ID));
    require(principal >= minLoan, "broker/dynamic-below-min-loan");
  }

  /**
   * @dev Validate that a fixed position is either fully repaid or has remaining principal
   *      at or above the minimum loan
   * @param position The fixed loan position to validate
   */
  function _validateFixedPosition(FixedLoanPosition memory position) internal view {
    uint256 remaining = position.principal - position.principalRepaid;
    if (remaining == 0) return;
    uint256 minLoan = MOOLAH.minLoan(_getMarketParams(MARKET_ID));
    require(remaining >= minLoan, "broker/fixed-below-min-loan");
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
    if (Id.unwrap(MARKET_ID) != bytes32(0)) revert InvalidMarket();
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
   * @notice updated by BOT role from time to time
   * @param term The fixed term and rate scheme
   * @param removeTerm True to remove the term, false to add or update
   */
  function updateFixedTermAndRate(FixedTermAndRate calldata term, bool removeTerm) external onlyRole(BOT) {
    if (term.termId == 0) revert InvalidTermId();
    if (term.duration == 0) revert InvalidDuration();
    if (term.apr < MIN_FIXED_TERM_APR || term.apr > MAX_FIXED_TERM_APR) revert InvalidAPR();
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
      revert TermNotFound();
    }
  }

  /**
   * @dev Set the maximum number of fixed loan positions a user can have
   * @param maxPositions The new maximum number of fixed loan positions
   */
  function setMaxFixedLoanPositions(uint256 maxPositions) external onlyRole(MANAGER) {
    if (maxFixedLoanPositions == maxPositions) revert SameValueProvided();
    emit MaxFixedLoanPositionsUpdated(maxFixedLoanPositions, maxPositions);
    maxFixedLoanPositions = maxPositions;
  }

  /**
   * @dev Pause or unpause the borrow function
   * @param paused True to pause, false to unpause
   */
  function setBorrowPaused(bool paused) external onlyRole(MANAGER) {
    if (borrowPaused == paused) revert SameValueProvided();
    borrowPaused = paused;
    emit BorrowPaused(paused);
  }

  /**
   * @dev Set the relayer address (one-time migration from immutable to storage)
   * @param _relayer The address of the BrokerInterestRelayer contract
   */
  function setRelayer(address _relayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_relayer != address(0), "broker/zero-address-provided");
    require(RELAYER == address(0), "broker/already-set");
    RELAYER = _relayer;
    emit RelayerSet(_relayer);
  }

  /**
   * @dev Set the oracle address (one-time migration from immutable to storage)
   * @param _oracle The address of the oracle
   */
  function setOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_oracle != address(0), "broker/zero-address-provided");
    require(address(ORACLE) == address(0), "broker/already-set");
    ORACLE = IOracle(_oracle);
    emit OracleSet(_oracle);
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
    if (isAddition == liquidationWhitelist.contains(account)) revert SameValueProvided();
    if (isAddition) {
      liquidationWhitelist.add(account);
      emit AddedLiquidationWhitelist(account);
    } else {
      liquidationWhitelist.remove(account);
      emit RemovedLiquidationWhitelist(account);
    }
  }

  /**
   * @dev Emergency withdraw a specific amount of an asset from the contract
   * @param token The token to withdraw, address(0) for native BNB
   * @param amount The amount to withdraw
   */
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    if (amount == 0) revert ZeroAmount();

    if (token == address(0)) {
      (bool success, ) = msg.sender.call{ value: amount }("");
      if (!success) revert NativeTransferFailed();
    } else {
      IERC20(token).safeTransfer(msg.sender, amount);
    }

    emit EmergencyWithdrawn(msg.sender, token, amount);
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

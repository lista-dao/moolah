// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ICreditBroker, FixedLoanPosition, FixedTermAndRate, GraceConfig } from "./interfaces/ICreditBroker.sol";
import { CreditBrokerMath, RATE_SCALE } from "./libraries/CreditBrokerMath.sol";
import { ICreditBrokerInterestRelayer } from "./interfaces/ICreditBrokerInterestRelayer.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

import { ICreditToken } from "../utils/interfaces/ICreditToken.sol";

/// @title Credit Loan Broker for Lista Lending
/// @author Lista DAO
/// @notice This contract allows users to borrow fixed-rate, fixed-term loans using credits as collateral.
/// @dev
/// - all borrow and repay has to be done through the broker, broker manages the positions
/// - collateral token is a credit token, which syncs user's credit score on every supply/withdraw
contract CreditBroker is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  ICreditBroker
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
  uint256 public constant MAX_FIXED_TERM_APR = 13e26; // 1.3 * RATE_SCALE = 30% MAX APR
  uint256 public constant MIN_FIXED_TERM_APR = 105 * 1e25; // 0.05 * RATE_SCALE = 5% MIN APR
  uint256 public constant MAX_REPAY_EXTENSION_COUNT = 3; // max 3 extensions

  address public LOAN_TOKEN;
  /// @dev credit token address
  address public COLLATERAL_TOKEN;

  /// @dev credit token address; used in `Moolah.setProvider`
  address public TOKEN;

  /// @dev LISTA token address; can be used to repay interest with discount
  address public LISTA;

  Id public MARKET_ID;
  string public BROKER_NAME;

  // ------- State variables -------

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

  // --- Grace config ---
  GraceConfig public graceConfig;

  /// @dev discount rate for repaying interest with LISTA token
  /// @dev 20% discount = 20 * 1e25; means user only need to pay 80% of interest in LISTA token
  uint256 listaDiscountRate;

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
   * @param lista The address of the LISTA token
   */
  constructor(address moolah, address relayer, address oracle, address lista) {
    // zero address assert
    require(moolah != address(0) && relayer != address(0) && oracle != address(0), "broker/zero-address-provided");
    // set addresses
    MOOLAH = IMoolah(moolah);
    RELAYER = relayer;
    ORACLE = IOracle(oracle);
    LISTA = lista;

    _disableInitializers();
  }

  /**
   * @dev Initialize the LendingBroker contract
   * @param _admin The address of the admin
   * @param _manager The address of the manager
   * @param _bot The address of the bot
   * @param _pauser The address of the pauser
   * @param _maxFixedLoanPositions The maximum number of fixed loan positions a user can have
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    uint256 _maxFixedLoanPositions
  ) public initializer {
    require(
      _admin != address(0) &&
        _manager != address(0) &&
        _bot != address(0) &&
        _pauser != address(0) &&
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
    maxFixedLoanPositions = _maxFixedLoanPositions;

    graceConfig.period = 3 days;
    graceConfig.penaltyRate = 15 * 1e25; // 15% = 0.15 * RATE_SCALE

    listaDiscountRate = 20 * 1e25; // 20% discount if repaying interest with LISTA

    emit GraceConfigUpdated(graceConfig.period, graceConfig.penaltyRate);
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev supply collateral(credit token) to Moolah
   * @param marketParams The market parameters
   * @param amount The amount of credit token to supply
   * @param score The credit score of the user
   * @param proof The merkle proof for credit score sync
   */
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) external override marketIdSet whenNotPaused nonReentrant {
    _supplyCollateral(marketParams, amount, score, proof);
  }

  /**
   * @dev supply collateral(credit token) and borrow an fixed amount with fixed term and rate
   * @param marketParams The market parameters
   * @param collateralAmount The amount of credit token to supply
   * @param borrowAmount amount to borrow
   * @param termId The ID of the term
   * @param score The credit score of the user
   * @param proof The merkle proof for credit score
   */
  function supplyAndBorrow(
    MarketParams memory marketParams,
    uint256 collateralAmount,
    uint256 borrowAmount,
    uint256 termId,
    uint256 score,
    bytes32[] calldata proof
  ) external override marketIdSet whenNotPaused whenBorrowNotPaused nonReentrant {
    _supplyCollateral(marketParams, collateralAmount, score, proof);
    _borrow(borrowAmount, termId);
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
    _borrow(amount, termId);
  }

  /**
   * @dev withdraw collateral(credit token) from Moolah
   * @param marketParams The market parameters
   * @param amount The amount of credit token to withdraw
   * @param proof The merkle proof for credit score sync
   */
  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) external override marketIdSet whenNotPaused nonReentrant {
    _withdrawCollateral(marketParams, amount, score, proof);
  }

  function repayAndWithdraw(
    MarketParams memory marketParams,
    uint256 collateralAmount,
    uint256 repayAmount,
    uint256 posId,
    uint256 score,
    bytes32[] calldata proof
  ) external override marketIdSet whenNotPaused nonReentrant {
    _repay(repayAmount, posId, msg.sender);
    _withdrawCollateral(marketParams, collateralAmount, score, proof);
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
    _repay(amount, posId, onBehalf);
  }

  /**
   * @dev Repay interest with LISTA token at a discount
   * @param loanTokenAmount The amount of loan token to repay apart from LISTA repayment
   * @param listaAmount The amount of LISTA token to use for interest repayment
   * @param posId The ID of the fixed position to repay
   * @param onBehalf The address of the user whose position to repay
   */
  function repayInterestWithLista(
    uint256 loanTokenAmount,
    uint256 listaAmount,
    uint256 posId,
    address onBehalf
  ) external override marketIdSet whenNotPaused nonReentrant {
    //    uint256 accruedInterest = _getAccruedInterestOnRepay(_getFixedPositionByPosId(onBehalf, posId));
    //    uint256 listaPrice = IOracle(ORACLE).peek(LISTA);

    //    uint256 maxListaValue = (accruedInterest * (RATE_SCALE - listaDiscountRate)) / RATE_SCALE;
    (uint256 maxListaAmount, uint256 listaPrice) = _getPayableLista(_getFixedPositionByPosId(onBehalf, posId));

    listaAmount = listaAmount > maxListaAmount ? maxListaAmount : listaAmount;

    // transfer LISTA from msg.sender, to Relayer
    IERC20(LISTA).safeTransferFrom(msg.sender, RELAYER, listaAmount);

    uint256 interestAmount = (listaAmount * listaPrice * RATE_SCALE) / (RATE_SCALE - listaDiscountRate) / 1e8;

    // transfer interest amount from Relayer to address(this)
    ICreditBrokerInterestRelayer(RELAYER).transferLoan(interestAmount);

    loanTokenAmount += interestAmount;

    _repay(loanTokenAmount, posId, onBehalf);
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
    if (asset == COLLATERAL_TOKEN) return 1e8;

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
    price = CreditBrokerMath.peek(token, user, address(MOOLAH), address(ORACLE));
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
   * @dev Check if a fixed position is penalized for overdue repayment
   * @param user The address of the user
   * @param posId The ID of the fixed position
   * @return True if the position is penalized, false otherwise
   */
  function isPositionPenalized(address user, uint256 posId) public view returns (bool) {
    FixedLoanPosition memory position = _getFixedPositionByPosId(user, posId);

    uint256 dueTime = position.end + graceConfig.period;
    return block.timestamp > dueTime;
  }

  /**
   * @dev Check if a user has any penalized fixed positions
   * @param user The address of the user
   * @return True if the user has any penalized positions, false otherwise
   */
  function isUserPenalized(address user) external view returns (bool) {
    FixedLoanPosition[] memory positions = fixedLoanPositions[user];

    bool penalized = false;

    for (uint256 i = 0; i < positions.length; i++) {
      uint256 posId = positions[i].posId;
      if (isPositionPenalized(user, posId)) {
        penalized = true;
        break;
      }
    }
    return penalized;
  }

  /**
   * @dev Get the total debt of a user (dynamic + fixed)
   * @param user The address of the user
   */
  function getUserTotalDebt(address user) public view override returns (uint256 totalDebt) {
    FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[user];
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      // add principal
      totalDebt += _fixedPos.principal - _fixedPos.principalRepaid;
      // add interest
      totalDebt += CreditBrokerMath.getAccruedInterestForFixedPosition(_fixedPos) - _fixedPos.interestRepaid;
    }
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
    (interestRepaid, penalty, principalRepaid) = CreditBrokerMath.previewRepayFixedLoanPosition(position, amount);
  }

  ///////////////////////////////////////
  /////        Bot functions        /////
  ///////////////////////////////////////

  ///////////////////////////////////////
  /////      Internal functions     /////
  ///////////////////////////////////////

  function _supplyCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) internal {
    require(marketParams.collateralToken == COLLATERAL_TOKEN, "broker/invalid-collateral-token");
    require(amount > 0, "broker/zero-amount");

    // sync msg.sender's credit score with creditToken balance before supplying collateral
    ICreditToken(COLLATERAL_TOKEN).syncCreditScore(msg.sender, score, proof);

    // ensure sufficient credit balance
    uint256 userCreditBalance = IERC20(COLLATERAL_TOKEN).balanceOf(msg.sender);
    require(userCreditBalance >= amount, "broker/insufficient-credit-balance");

    // transfer collateral from msg.sender to broker
    IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
    // approve to moolah
    IERC20(COLLATERAL_TOKEN).safeIncreaseAllowance(address(MOOLAH), amount);
    // supply to moolah
    MOOLAH.supplyCollateral(marketParams, amount, msg.sender, "");
  }

  function _withdrawCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    uint256 score,
    bytes32[] calldata proof
  ) internal {
    require(marketParams.collateralToken == COLLATERAL_TOKEN, "broker/invalid-collateral-token");
    require(amount > 0, "broker/zero-amount");

    // withdraw from moolah
    MOOLAH.withdrawCollateral(marketParams, amount, msg.sender, address(this));

    // transfer to msg.sender
    IERC20(COLLATERAL_TOKEN).safeTransfer(msg.sender, amount);

    // sync msg.sender's credit score with creditToken balance after withdrawing collateral
    ICreditToken(COLLATERAL_TOKEN).syncCreditScore(msg.sender, score, proof);
  }

  function _borrow(uint256 amount, uint256 termId) internal {
    require(amount > 0, "broker/zero-amount");
    address user = msg.sender;
    require(fixedLoanPositions[user].length < maxFixedLoanPositions, "broker/exceed-max-fixed-positions");
    // get term by Id
    FixedTermAndRate memory term = _getTermById(termId);
    // prepare position info
    uint256 start = block.timestamp;
    uint256 end = block.timestamp + term.duration;
    // pos uuid increment
    fixedPosUuid++;
    // update state for user's fixed positions
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

    // borrow from moolah
    _borrowFromMoolah(user, amount);
    // transfer loan token to user
    IERC20(LOAN_TOKEN).safeTransfer(user, amount);
    // validate positions
    _validatePositions(user);
    // emit event
    emit FixedLoanPositionCreated(user, fixedPosUuid, amount, start, end, term.apr, termId);
  }

  function _getPayableLista(FixedLoanPosition memory position) internal view returns (uint256, uint256) {
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.principalRepaid;

    // get outstanding accrued interest
    uint256 accruedInterest = _getAccruedInterestForFixedPosition(position) - position.interestRepaid;
    uint256 listaPrice = IOracle(ORACLE).peek(LISTA);

    uint256 maxListaValue = (accruedInterest * (RATE_SCALE - listaDiscountRate)) / RATE_SCALE;
    uint256 payableListaAmount = (maxListaValue * 1e8) / listaPrice;

    return (payableListaAmount, listaPrice);
  }

  function _repay(uint256 amount, uint256 posId, address onBehalf) internal {
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

    uint256 penalty = 0;
    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // ----- delay penalty
      // check penalty if user is repaying after grace period ends
      // penalty = 15% * debt
      uint256 debt = remainingPrincipal + accruedInterest;
      penalty = _getDelayPenalty(repayPrincipalAmt, remainingPrincipal, debt, position.end);

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
      // log paid off penalized position
      if (penalty > 0) {
        emit PaidOffPenalizedPosition(user, posId, block.timestamp);
      }
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
      ICreditBrokerInterestRelayer(RELAYER).supplyToVault(interest);
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

  ///  | ---- Fixed term --- | ---- Grace period ---- |
  /// start                 end                    dueTime
  function _getDelayPenalty(
    uint256 repayAmt,
    uint256 remainingPrincipal,
    uint256 debt,
    uint256 endTime
  ) internal view returns (uint256 penalty) {
    if (graceConfig.period == 0) return 0;

    uint256 dueTime = endTime + graceConfig.period;
    // if within grace period, no penalty
    if (block.timestamp <= dueTime) return 0;

    // maximum repayable amount = remaining principal + penalty on the debt
    uint256 maxRepayable = remainingPrincipal + (debt * graceConfig.penaltyRate) / RATE_SCALE;

    // if repay amount exceeds max repayable (debt + penalty), cap it
    if (repayAmt > maxRepayable) {
      repayAmt = maxRepayable;
    }

    // calculate penalty on the debt; 15%
    penalty = (repayAmt * graceConfig.penaltyRate) / RATE_SCALE;
  }

  /**
   * @dev Get the interest for a fixed loan position
   * @param position The fixed loan position to get the interest for
   */
  function _getAccruedInterestForFixedPosition(FixedLoanPosition memory position) internal view returns (uint256) {
    return CreditBrokerMath.getAccruedInterestForFixedPosition(position);
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
    return CreditBrokerMath.getPenaltyForFixedPosition(position, repayAmt);
  }

  /**
   * @dev Validate that the user's positions meet the minimum loan requirement
   * @param user The address of the user
   */
  function _validatePositions(address user) internal view {
    FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[user];
    // assume valid first
    bool isValid = true;
    uint256 minLoan = MOOLAH.minLoan(MOOLAH.idToMarketParams(MARKET_ID));

    // check fixed positions
    for (uint256 i = 0; i < fixedPositions.length; i++) {
      FixedLoanPosition memory _fixedPos = fixedPositions[i];
      uint256 fixedPosDebt = _fixedPos.principal - _fixedPos.principalRepaid;
      if (fixedPosDebt > 0 && fixedPosDebt < minLoan) {
        isValid = false;
      }
    }

    require(isValid, "broker/position-below-min-loan");
  }

  function liquidate(
    MarketParams memory,
    address,
    uint256,
    uint256,
    bytes calldata
  ) external marketIdSet whenNotPaused nonReentrant {
    revert("creditBroker/not-support-liquidation");
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
    TOKEN = _marketParams.collateralToken;

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
    require(term.termId > 0, "broker/invalid-term-id");
    require(term.duration > 0, "broker/invalid-duration");
    require(term.apr >= MIN_FIXED_TERM_APR && term.apr <= MAX_FIXED_TERM_APR, "broker/invalid-apr");
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

  function setGraceConfig(uint256 period, uint256 penaltyRate) external onlyRole(MANAGER) {
    require(graceConfig.period != period || graceConfig.penaltyRate != penaltyRate, "broker/same-value-provided");
    require(penaltyRate <= RATE_SCALE, "broker/invalid-penalty-rate");

    graceConfig.period = period;
    graceConfig.penaltyRate = penaltyRate;

    emit GraceConfigUpdated(period, penaltyRate);
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

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

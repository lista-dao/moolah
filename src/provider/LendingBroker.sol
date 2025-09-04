// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate } from "./interfaces/IBroker.sol";
import { BrokerMath } from "./libraries/BrokerMath.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market } from "../moolah/interfaces/IMoolah.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";
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

  // ------- Roles -------
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");

  // ------- Immutables -------
  IMoolah public immutable MOOLAH;
  IMoolahVault public immutable MOOLAH_VAULT;
  IOracle public immutable ORACLE;
  address public immutable LOAN_TOKEN;
  address public immutable COLLATERAL_TOKEN;
  Id public immutable MARKET_ID;
  string public BROKER_NAME;

  // ------- State variables -------

  // --- Dynamic rate loan
  // user => dynamic loan position
  mapping(address => DynamicLoanPosition) public dynamicLoanPositions;
  // latest rate factor
  uint256 public currentRate;
  // timestamp of last rate calculation
  uint256 public lastCompounded;

  // --- Fixed rate and terms
  // Fixed term and rate products
  FixedTermAndRate[] public fixedTerms;
  // user => fixed loan positions
  mapping(address => FixedLoanPosition[]) public fixedLoanPositions;
  // how many fixed loan positions a user can have
  uint256 public maxFixedLoanPositions;

  // ------- Modifiers -------
  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "Broker/not-moolah");
    _;
  }

  /**
   * @dev Constructor for the LendingBroker contract
   * @param moolah The address of the Moolah contract
   * @param moolahVault The address of the MoolahVault contract
   * @param oracle The address of the oracle
   * @param marketId The ID of the market
   */
  constructor(
    address moolah,
    address moolahVault,
    address oracle,
    Id marketId
  ) {
    // zero address assert
    require(
      moolah != address(0) && 
      moolahVault != address(0) && 
      oracle != address(0),
      ErrorsLib.ZERO_ADDRESS
    );
    // set addresses
    MOOLAH = IMoolah(moolah);
    MOOLAH_VAULT = IMoolahVault(moolahVault);
    ORACLE = IOracle(oracle);
    MARKET_ID = marketId;
    MarketParams memory _marketParams = MOOLAH.idToMarketParams(marketId);
    LOAN_TOKEN = _marketParams.loanToken;
    COLLATERAL_TOKEN = _marketParams.collateralToken;

    _disableInitializers();
  }

  /**
   * @dev Initialize the LendingBroker contract
   * @param admin The address of the admin
   * @param manager The address of the manager
   * @param bot The address of the bot
   * @param pauser The address of the pauser
   * @param maxFixedLoanPositions The maximum number of fixed loan positions a user can have
   */
  function initialize(
    address admin,
    address manager,
    address bot,
    address pauser,
    uint256 maxFixedLoanPositions
  ) public initializer {
    require(
      admin != address(0) &&
      manager != address(0) &&
      bot != address(0) &&
      pauser != address(0),
      ErrorsLib.ZERO_ADDRESS
    );
    
    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    // grant roles
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
    _grantRole(PAUSER, pauser);
    // init state variables
    maxFixedLoanPositions = maxFixedLoanPositions;

    // set broker name
    string memory collateralTokenName = IERC20Metadata(COLLATERAL_TOKEN).symbol();
    string memory loanTokenName = IERC20Metadata(LOAN_TOKEN).symbol();
    BROKER_NAME = string(abi.encodePacked("Lista-Lending ", collateralTokenName, "-", loanTokenName, " Broker"));
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Borrow a fixed amount with a dynamic rate
   * @param amount The amount to borrow
   */
  function borrow(uint256 amount) external override whenNotPaused nonReentrant {
    require(amount > 0, ErrorsLib.ZERO_ASSETS);
    address user = msg.sender;
  }

  /**
    * @dev borrow an fixed amount with fixed term and rate
    *      user is not allowed to alter the position once it has been created
    *      but user can repay the loan at any time
    * @param amount amount to borrow
    * @param termId The ID of the term
    */
  function borrow(uint256 amount, uint256 termId) external override whenNotPaused nonReentrant {
    require(amount > 0, "broker/amount-zero");
    address user = msg.sender;
    // borrow from moolah
    _borrowFromMoolah(user, amount);
    // get term by Id
    FixedTermAndRate memory term = _getTermById(termId);
    // prepare position info
    uint256 start = block.timestamp;
    uint256 end = block.timestamp + term.duration;
    // update state
    fixedLoanPositions[user].push(FixedLoanPosition({
      principal: amount,
      apr: term.apr,
      start: start,
      end: end,
      lastRepaidTime: start,
      repaidPrincipal: 0
    }));
    // emit event
    emit FixedLoanPositionCreated(user, amount, start, end, term.apr, termId);
  }

  function convertDynamicToFixed(address user, uint256 amount, uint256 termId) external whenNotPaused nonReentrant {

  }

  function repay(uint256 amount) external override whenNotPaused nonReentrant {

  }

  /**
    * @dev Repay a Fixed loan position
    * @notice repay interest first then principal, repay amount must larger than interest
    * @param amount The amount to repay
    * @param posIdx The index of the fixed position to repay
   */
  function repay(uint256 amount, uint256 posIdx) external override whenNotPaused nonReentrant {
    address user = msg.sender;
    require(posIdx < fixedLoanPositions[user].length, "broker/invalid-position");
    FixedLoanPosition memory position = fixedLoanPositions[user][posIdx];

    // remaining principal, user might repaid before
    uint256 remainingPrincipal = position.principal - position.repaidPrincipal;

    // calculate interest
    uint256 interest = _getAccruedInterestForFixedPosition(position);
    require(amount > interest, "broker/repay-amount-insufficient");

    // calculate penalty (zero if there is no penalty)
    uint256 penalty = _getPenaltyForFixedPosition(position, amount - interest);
    // total interest and penalty required (does not include principal)
    uint256 interestAndPenalty = interest + penalty;
    // repay amount must be larger than interest and penalty
    require(interestAndPenalty < amount, "broker/repay-amount-insufficient");

    // transfer loan tokens from user
    IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), amount);
    // supply interest into vault as revenue
    _supplyToMoolah(interestAndPenalty);
    // repay principal with the remaining amount
    uint256 repaidAmount = amount - interestAndPenalty;
    // amount left fully covers remaining principal
    if (repaidAmount > remainingPrincipal) {
      // repay all remaining principal
      _repayToMoolah(user, remainingPrincipal);
      // transfer unused amount
      IERC20(LOAN_TOKEN).safeTransfer(user, repaidAmount - remainingPrincipal);
      // removes it from user's fixed positions
      _removeFixPositionAtIdx(user, posIdx);
    } else {
      // repay with all amount left
      _repayToMoolah(user, repaidAmount);
      // the rest will be used to repay partially
      position.repaidPrincipal += repaidAmount;
      // update position
      fixedLoanPositions[user][posIdx] = position;
    }
    // emit event
    emit RepaidFixedLoanPosition(
      user,
      position.principal,
      position.start,
      position.end,
      position.apr,
      position.repaidPrincipal,
      repaidAmount > remainingPrincipal
    );
  }

  function liquidate(Id id, address user) external override whenNotPaused nonReentrant {

  }


  ///////////////////////////////////////
  /////        View functions       /////
  ///////////////////////////////////////
  function getFixedTerms() external view override returns (FixedTermAndRate[] memory) {
    return fixedTerms;
  }

  function peek(address token, address user) external override view returns (uint256 price) {
    // total interest (Fixed + Dynamic position)
    uint256 totalInterest = 0;
    // [1] interest from fixed positions
    FixedLoanPosition[] memory positions = fixedLoanPositions[user];
    for (uint256 i = 0; i < positions.length; i++) {
      totalInterest += _getAccruedInterestForFixedPosition(positions[i]);
    }
    // @todo [2] interest from dynamic positions
  }

  function userFixedPositions(address user) external view returns (FixedLoanPosition[] memory) {
    return fixedLoanPositions[user];
  }

  function userDynamicPosition(address user) external view returns (DynamicLoanPosition memory) {

  }

  ///////////////////////////////////////
  /////        Bot functions        /////
  ///////////////////////////////////////
  function refinanceExpiredToDynamic(address user, uint256[] calldata positionIdxs) 
  external
  override
  whenNotPaused
  nonReentrant
  onlyRole(BOT) {

  }

  function upkeepInterest() external whenNotPaused nonReentrant {

  }

  ///////////////////////////////////////
  /////      Internal functions     /////
  ///////////////////////////////////////

  /**
   * @dev Get the market parameters for this broker
   */
  function _getMarketParams() internal view returns (MarketParams memory) {
    return MOOLAH.idToMarketParams(MARKET_ID);
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
    MarketParams memory marketParams = _getMarketParams();
    // pre-balance
    uint256 preBalance = IERC20(LOAN_TOKEN).balanceOf(address(this));
    // borrow from moolah with zero interest
    MOOLAH.borrow(
      marketParams,
      amount,
      0,
      onBehalf,
      address(this)
    );
    // should increase the loan balance same as borrowed amount
    require(
      IERC20(LOAN_TOKEN).balanceOf(address(this)) - preBalance == amount,
      "broker/invalid-borrowed-amount"
    );
  }

  /**
   * @dev Repay an amount on behalf of a user to Moolah
   * @param onBehalf The address of the user to repay on behalf of
   * @param amount The amount to repay
   */
  function _repayToMoolah(address onBehalf, uint256 amount) internal {
    MarketParams memory marketParams = _getMarketParams();
    // repay to moolah
    MOOLAH.repay(
      marketParams,
      amount,
      0,
      onBehalf,
      ""
    );
  }

  /**
   * @dev Supply an amount of interest to Moolah
   * @param interest The amount of interest to supply
   */
  function _supplyToMoolah(uint256 interest) internal {
    if (interest > 0) {
      // approve to Moolah
      IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), interest);
      // supply interest into vault as revenue
      (uint256 suppliedAmount, /*uint256 shares */) = MOOLAH.supply(
        _getMarketParams(),
        interest,
        0,
        address(MOOLAH_VAULT),
        ""
      );
    }
  }

  /**
   * @dev removes a user's fixed-loan position at a specific index
   * @param user The address of the user
   * @param posIdx The index of the position to remove
   */
  function _removeFixPositionAtIdx(address user, uint256 posIdx) internal {
    // get user's fixed positions
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    require(posIdx < positions.length, "broker/invalid-position");
    // remove position
    positions[posIdx] = positions[positions.length - 1];
    positions.pop();
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
  function _getPenaltyForFixedPosition(FixedLoanPosition memory position, uint256 repayAmt) internal view returns (uint256 penalty) {
    return BrokerMath.getPenaltyForFixedPosition(position, repayAmt);
  }

  function _compoundInterest() internal view {
    require(block.timestamp >= lastCompounded, "Broker/invalid-now");
    /*
    // compounding new rate factor with time elapsed
    currentRate = BrokerMath.calculateNewRate(
      base,
      currentRate,
      block.timestamp - lastCompounded
    );
    // record last compounded timestamp
    lastCompounded = block.timestamp;
    */
  }

  ///////////////////////////////////////
  /////       Admin functions       /////
  ///////////////////////////////////////

  /**
   * @dev Set a fixed term and rate for borrowing
   * @param termId The ID of the fixed term
   * @param duration The duration of the fixed term (in seconds)
   * @param apr The percentage rate for the fixed term
   */
  function setFixedTermAndRate(uint256 termId, uint256 duration, uint256 apr) external onlyRole(MANAGER) {
    require(termId > 0, "broker/invalid-term-id");
    require(duration > 0, "broker/invalid-duration");
    require(apr > 0 && apr < BrokerMath.DENOMINATOR, "broker/invalid-apr");
    FixedTermAndRate memory _term = FixedTermAndRate({
      termId: termId,
      duration: duration,
      apr: apr
    });
    // emit event first
    emit FixedTermAndRateUpdated(termId, duration, apr);
    // update term if it exists
    for(uint256 i = 0; i < fixedTerms.length; i++) {
      if (fixedTerms[i].termId == termId) {
        fixedTerms[i] = _term;
        return;
      }
    }
    // does not exist, add it
    fixedTerms.push(_term);
  }

  /**
   * @dev Remove a fixed term and rate for borrowing
   * @param termId The ID of the fixed term to remove
   */
  function removeFixedTermAndRate(uint256 termId) external onlyRole(MANAGER) {
    require(termId > 0, "broker/invalid-term-id");
    for(uint256 i = 0; i < fixedTerms.length; i++) {
      if (fixedTerms[i].termId == termId) {
        fixedTerms[i] = fixedTerms[fixedTerms.length - 1];
        fixedTerms.pop();
        return;
      }
    }
    revert("broker/term-not-found");
  }

  /**
   * @dev Set the maximum number of fixed loan positions a user can have
   * @param maxPositions The new maximum number of fixed loan positions
   */ 
  function setMaxFixedLoanPositions(uint256 maxPositions) external onlyRole(MANAGER) {
    require(maxFixedLoanPositions != maxPositions, ErrorsLib.INCONSISTENT_INPUT);
    uint256 oldMaxFixedLoanPositions = maxFixedLoanPositions;
    maxFixedLoanPositions = maxPositions;
    emit MaxFixedLoanPositionsUpdated(oldMaxFixedLoanPositions, maxPositions);
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

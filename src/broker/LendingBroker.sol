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
import { IRateCalculator } from "./interfaces/IRateCalculator.sol";
import { BrokerMath, RATE_SCALE } from "./libraries/BrokerMath.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market, Position } from "../moolah/interfaces/IMoolah.sol";
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
  using UtilsLib for uint256;

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
      ErrorsLib.ZERO_ADDRESS
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
    fixedPosUuid = 1;
    
    // set broker name
    string memory collateralTokenName = IERC20Metadata(COLLATERAL_TOKEN).symbol();
    string memory loanTokenName = IERC20Metadata(LOAN_TOKEN).symbol();
    BROKER_NAME = string(abi.encodePacked("Lista-Lending ", collateralTokenName, "-", loanTokenName, " Broker"));
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Borrow a fixed amount of loan token with a dynamic rate
   * @param amount The amount to borrow
   */
  function borrow(uint256 amount) external override whenNotPaused nonReentrant {
    require(amount > 0, ErrorsLib.ZERO_ASSETS);
    address user = msg.sender;
    // get updated rate
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    // calc. normalized debt
    uint256 normalizedDebt = BrokerMath.normalizeBorrowAmount(amount, rate);
    // update user's dynamic position
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    position.principal += amount;
    position.normalizedDebt += normalizedDebt;
    // borrow from moolah
    _borrowFromMoolah(user, amount);
    // transfer loan token to user
    IERC20(LOAN_TOKEN).safeTransfer(user, amount);
    // emit event
    emit DynamicLoanPositionUpdated(user, amount, position.principal);
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
      posId: fixedPosUuid,
      principal: amount,
      apr: term.apr,
      start: start,
      end: end,
      lastRepaidTime: start,
      repaidPrincipal: 0
    }));
    // pos uuid increment
    fixedPosUuid++;
    // transfer loan token to user
    IERC20(LOAN_TOKEN).safeTransfer(user, amount);
    // emit event
    emit FixedLoanPositionCreated(user, amount, start, end, term.apr, termId);
  }

  /**
    * @dev Repay a Dynamic loan position
    * @param amount The amount to repay
   */
  function repay(uint256 amount) external override whenNotPaused nonReentrant {
    require(amount > 0, ErrorsLib.ZERO_ASSETS);
    address user = msg.sender;
    // transfer from user
    IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), amount);
    // get user's dynamic position
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    // get updated rate
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    // calc. actual debt (borrowed amount + accrued interest)
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    // get net accrued interest
    uint256 accruedInterest = actualDebt - position.principal;
    require(amount > accruedInterest, "broker/repay-amount-insufficient");
    // collect interest and supply to moolah
    _supplyToMoolah(accruedInterest);
    // deduct net accrued interest from repayment amount
    amount -= accruedInterest;
    // update position
    position.principal -= amount;
    position.normalizedDebt -= BrokerMath.normalizeBorrowAmount(amount, rate);
    // repay to moolah
    _repayToMoolah(user, amount);
    // emit event
    emit DynamicLoanPositionUpdated(user, amount, position.principal);
  }

  /**
    * @dev Repay a Fixed loan position
    * @notice repay interest first then principal, repay amount must larger than interest
    * @param amount The amount to repay
    * @param posId The ID of the fixed position to repay
   */
  function repay(uint256 amount, uint256 posId) external override whenNotPaused nonReentrant {
    address user = msg.sender;
    // fetch position (will revert if not found)
    FixedLoanPosition memory position = _getFixedPositionByPosId(user, posId);

    // transfer from user
    IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), amount);
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
      _removeFixPositionByPosId(user, posId);
    } else {
      // repay with all amount left
      _repayToMoolah(user, repaidAmount);
      // the rest will be used to repay partially
      position.repaidPrincipal += repaidAmount;
      // update position
      _updateFixedPosition(user, position);
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

  ///////////////////////////////////////
  /////         Liquidation         /////
  ///////////////////////////////////////

  /**
   * @dev Liquidate a borrower's debt by accruing interest and repaying the dynamic
   *      position first, then settling fixed-rate positions sorted by APR and
   *      remaining principal. The last fixed position absorbs any rounding delta.
   * @param id The market id
   * @param user The address of the user being liquidated
   */
  function liquidate(Id id, address user) external override onlyMoolah whenNotPaused nonReentrant {
    require(
      _getMarketParams(id).loanToken == _getMarketParams(MARKET_ID).loanToken &&
      _getMarketParams(id).collateralToken == _getMarketParams(MARKET_ID).collateralToken
      ,"Broker/invalid-market");
    require(user != address(0), "Broker/invalid-user");
    // fetch positions
    DynamicLoanPosition storage dynamicPosition = dynamicLoanPositions[user];
    FixedLoanPosition[] memory fixedPositions = fixedLoanPositions[user];
    // [1] calculate total outstanding debt before liquidation (principal + interest)
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    uint256 totalDebt = BrokerMath.getTotalDebt(fixedPositions, dynamicPosition, rate);
    // [2] calculate actual debt at Moolah after liquidation
    Market memory market = MOOLAH.market(id);
    Position memory mPos = MOOLAH.position(id, user);
    // thats how much user borrowed from Moolah (0% interest, should = total principal at LendingBroker)
    // after liquidation, this will be the new debt amount (partial of collateral has been liquidated)
    uint256 debtAfter = uint256(mPos.borrowShares).toAssetsUp(
      market.totalBorrowAssets,
      market.totalBorrowShares
    );
    // debt at broker > debt at moolah, we need to deduct the diff from positions
    uint256 principalToDeduct = totalDebt.zeroFloorSub(debtAfter);
    if (principalToDeduct == 0) return;
    // deduct from dynamic position and returns the leftover assets to deduct
    principalToDeduct = _deductDynamicPositionDebt(dynamicPosition, principalToDeduct, rate);
    // deduct from fixed positions
    if (principalToDeduct > 0 && fixedPositions.length > 0) {
      // sort fixed positions from highest APR + remaining principal
      FixedLoanPosition[] memory sorted = _sortAndFilterFixedPositions(fixedPositions);
      if (sorted.length > 0) {
        _deductFixedPositionsDebt(user, sorted, principalToDeduct);
      }
    }
    // emit event
    emit Liquidated(user, principalToDeduct);
  }

  /**
   * @dev insertion sort positions by APR(desc) then remaining principal(desc)
   *      insertion sort is not gas efficient algorithm,
   *      but it is simple and works well for small arrays as user's number of fixed positions is limited
   * @param positions The fixed loan positions to sort
   */
  function _sortAndFilterFixedPositions(
    FixedLoanPosition[] memory positions
  ) internal pure returns (FixedLoanPosition[] memory) {
    uint256 len = positions.length;
    FixedLoanPosition[] memory filtered = new FixedLoanPosition[](len);
    uint256 count;
    for (uint256 i = 0; i < len; i++) {
      FixedLoanPosition memory p = positions[i];
      if (p.principal > p.repaidPrincipal) {
        uint256 remaining = p.principal - p.repaidPrincipal;
        uint256 j = count;
        while (j > 0) {
          FixedLoanPosition memory prev = filtered[j - 1];
          uint256 prevRemaining = prev.principal - prev.repaidPrincipal;
          if (prev.apr > p.apr || (prev.apr == p.apr && prevRemaining >= remaining)) {
            break;
          }
          filtered[j] = prev;
          j--;
        }
        filtered[j] = p;
        count++;
      }
    }
    // trim `filtered` to length `count`
    assembly { mstore(filtered, count) }
    return filtered;
  }

  /**
   * @dev deducts debt from the dynamic position and returns leftover assets
   * @param position The dynamic loan position to modify
   * @param principalToDeduct The amount of assets repaid during liquidation, leads to deduct from principal and interest
   * @param rate The current interest rate
   */
  function _deductDynamicPositionDebt(
    DynamicLoanPosition storage position,
    uint256 principalToDeduct,
    uint256 rate
  ) internal returns (uint256) {
    // get debt at dynamic position
    uint256 dynamicDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    if (dynamicDebt > 0) {
      // calculate the amount to deduct from principal
      uint256 amountToDeduct = UtilsLib.min(dynamicDebt, principalToDeduct);
      if (amountToDeduct > 0) {
        // deduct principal
        uint256 principalToRepay = UtilsLib.min(position.principal, amountToDeduct);
        position.principal -= principalToRepay;
        // deduct normalized debt
        uint256 normalizedDebtDelta = BrokerMath.normalizeBorrowAmount(amountToDeduct, rate);
        position.normalizedDebt = position.normalizedDebt.zeroFloorSub(normalizedDebtDelta);
        // partially(or fully) deduct repaid assets from dynamic position
        principalToDeduct -= amountToDeduct;
      }
    }
    return principalToDeduct;
  }

  /**
   * @dev allocates repayments to fixed positions by APR and remaining principal
   * @param user The address of the user
   * @param sortedFixedPositions The sorted fixed loan positions
   * @param principalToDeduct The amount of assets repaid during liquidation, leads to deduct from principal and interest
   */
  function _deductFixedPositionsDebt(
    address user,
    FixedLoanPosition[] memory sortedFixedPositions,
    uint256 principalToDeduct
  ) internal {
    uint256 len = sortedFixedPositions.length;
    for (uint256 i = 0; i < len; i++) {
      FixedLoanPosition memory p = sortedFixedPositions[i];
      // get remaining principal
      uint256 principalRemain = p.principal - p.repaidPrincipal;
      // get accrued interest
      uint256 interest = BrokerMath.getAccruedInterestForFixedPosition(p);
      // calculate total debt
      uint256 debt = principalRemain + interest;
      // determine the amount to deduct from principal
      // if it comes to the last position, deduct all remaining principal
      uint256 amountToDeduct = (i == len - 1) ? principalToDeduct : UtilsLib.min(debt, principalToDeduct);
      if (amountToDeduct > 0) {
        // deduct interest first
        uint256 repayInterest = UtilsLib.min(interest, amountToDeduct);
        amountToDeduct -= repayInterest;
        // deduct principal
        uint256 repayPrincipal = UtilsLib.min(principalRemain, amountToDeduct);
        if (repayPrincipal > 0) {
          p.repaidPrincipal += repayPrincipal;
          p.lastRepaidTime = block.timestamp;
        }
        // deduct interest and principal from total
        principalToDeduct -= (repayInterest + repayPrincipal);
      }
      // remove it if fully repaid, otherwise update it
      if (p.repaidPrincipal >= p.principal) {
        _removeFixPositionByPosId(user, p.posId);
      } else {
        _updateFixedPosition(user, p);
      }
      // terminate process if all deduction is complete
      if (principalToDeduct == 0) break;
    }
  }

  ///////////////////////////////////////
  /////        View functions       /////
  ///////////////////////////////////////
  function getFixedTerms() external view override returns (FixedTermAndRate[] memory) {
    return fixedTerms;
  }

  /**
   * @dev returns the price of a token for a user in 8 decimal places
   * @param token The address of the token to get the price for
   * @param user The address of the user
   */
  function peek(address token, address user) external override view returns (uint256 price) {
    // loan token's price never changes
    if (token == LOAN_TOKEN) {
      return 10 ** 8;
    } else if(token == COLLATERAL_TOKEN) {
      /*
        Broker accrues interest, so collateral price is adjusted downward,
        this lets Moolah detect risk as interest grows, despite its 0% rate.
        [A] Collateral Market Price
        [B] Broker Total Debt (included interest)
        [C] Moolah Debt (0% rate)
        [D] Collateral Amount
        new collateral price  = A - (B-C)/D
      */
      // the total debt of the user (principal + interest)
      uint256 debtAtBroker = BrokerMath.getTotalDebt(
        fixedLoanPositions[user],
        dynamicLoanPositions[user],
        IRateCalculator(rateCalculator).getRate(address(this))
      );
      // fetch collateral price from oracle
      uint256 collateralPrice = IOracle(ORACLE).peek(COLLATERAL_TOKEN);
      // get user's position info
      Position memory _position = MOOLAH.position(MARKET_ID, user);
      // get market info
      Market memory _market = MOOLAH.market(MARKET_ID);
      // convert shares to borrowed amount (Moolah's debt)
      uint256 debtAtMoolah = uint256(_position.borrowShares).toAssetsUp(
        _market.totalBorrowAssets,
        _market.totalBorrowShares
      );
      // calculate manipulated price
      price = collateralPrice - BrokerMath.mulDivCeiling(
        debtAtBroker - debtAtMoolah,
        1e10,
        _position.collateral
      );
    }
    revert("Broker/unsupported-token");
  }

  function userFixedPositions(address user) external view returns (FixedLoanPosition[] memory) {
    return fixedLoanPositions[user];
  }

  function userDynamicPosition(address user) external view returns (DynamicLoanPosition memory) {
    return dynamicLoanPositions[user];
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
  function refinanceMaturedFixedPositions(address user, uint256[] calldata posIds) 
  external
  override
  whenNotPaused
  nonReentrant
  onlyRole(BOT) {
    require(posIds.length > 0, "Broker/zero-positions");
    // the additional principal will be add into the dynamic position
    uint256 _principal = 0;
    // calculate principal to be refinanced one by one
    for (uint256 i = 0; i < posIds.length; i++) {
      uint256 posId = posIds[i];
      // fetch fixed position and make sure it's matured
      FixedLoanPosition memory position = _getFixedPositionByPosId(user, posId);
      require(block.timestamp >= position.end, "Broker/position-not-expired");
      // Debt of a fixed loan position consist of (1) and (2)
      // (1) net principal to pay (original principal - repaid principal)
      // (2) get accrued interest if user has repaid before, partial of the interest will be excluded
      _principal +=
        position.principal - position.repaidPrincipal +
        _getAccruedInterestForFixedPosition(position);
    }
    if (_principal > 0) {
      // get updated rate
      uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
      // calc. normalized debt
      uint256 normalizedDebt = BrokerMath.normalizeBorrowAmount(_principal, rate);
      // update user's dynamic position
      DynamicLoanPosition storage position = dynamicLoanPositions[user];
      position.principal += _principal;
      position.normalizedDebt += normalizedDebt;
      // emit the same event as borrow with dynamic position
      emit DynamicLoanPositionUpdated(user, _principal, position.principal);
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
    // approve
    IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), amount);
    MarketParams memory marketParams = _getMarketParams(MARKET_ID);
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
        _getMarketParams(MARKET_ID),
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
   * @param posId The ID of the position to remove
   */
  function _removeFixPositionByPosId(address user, uint256 posId) internal {
    // get user's fixed positions
    FixedLoanPosition[] storage positions = fixedLoanPositions[user];
    // loop through user's positions
    for (uint256 i = 0; i < positions.length; i++) {
      if (positions[i].posId == posId) {
        // remove position
        positions[i] = positions[positions.length - 1];
        positions.pop();
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
  function _getPenaltyForFixedPosition(FixedLoanPosition memory position, uint256 repayAmt) internal view returns (uint256 penalty) {
    return BrokerMath.getPenaltyForFixedPosition(position, repayAmt);
  }

  /**
   * @dev Get the accrued interest for a dynamic loan position
   * @param position The dynamic loan position to get the accrued interest for
   */
  function _getAccruedInterestForDynamicPosition(DynamicLoanPosition memory position) internal view returns (uint256 accruedInterest) {
    // get updated rate
    uint256 rate = IRateCalculator(rateCalculator).getRate(address(this));
    // calc. actual debt (borrowed amount + accrued interest)
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    // get net accrued interest
    accruedInterest = actualDebt - position.principal;
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
    require(apr >= RATE_SCALE, "broker/invalid-apr");
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

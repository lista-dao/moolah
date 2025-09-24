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

  // ------- Modifiers -------
  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "Broker/not-moolah");
    _;
  }

  modifier marketIdSet() {
    require(Id.unwrap(MARKET_ID) != bytes32(0), "Broker/market-not-set");
    _;
  }

  /**
   * @dev Constructor for the LendingBroker contract
   * @param moolah The address of the Moolah contract
   * @param moolahVault The address of the MoolahVault contract
   * @param oracle The address of the oracle
   */
  constructor(
    address moolah,
    address moolahVault,
    address oracle
  ) {
    // zero address assert
    require(
      moolah != address(0) && 
      moolahVault != address(0) && 
      oracle != address(0),
      "broker/zero-address-provided"
    );
    // set addresses
    MOOLAH = IMoolah(moolah);
    MOOLAH_VAULT = IMoolahVault(moolahVault);
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
    fixedPosUuid = 1;
  }

  ///////////////////////////////////////
  /////      External functions     /////
  ///////////////////////////////////////

  /**
   * @dev Borrow a fixed amount of loan token with a dynamic rate
   * @param amount The amount to borrow
   */
  function borrow(uint256 amount) external override marketIdSet whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
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
    emit DynamicLoanPositionBorrowed(user, amount, position.principal);
  }

  /**
    * @dev borrow an fixed amount with fixed term and rate
    *      user is not allowed to alter the position once it has been created
    *      but user can repay the loan at any time
    * @param amount amount to borrow
    * @param termId The ID of the term
    */
  function borrow(uint256 amount, uint256 termId) external override marketIdSet whenNotPaused nonReentrant {
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
    // update state
    fixedLoanPositions[user].push(FixedLoanPosition({
      posId: fixedPosUuid,
      principal: amount,
      apr: term.apr,
      start: start,
      end: end,
      repaidInterest: 0,
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
    uint256 accruedInterest = 
      BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate) - position.principal;
    // calculate the amount we need to repay for interest and principal
    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 amountLeft = amount - repayInterestAmt;
    uint256 repayPrincipalAmt = amountLeft > position.principal ? position.principal : amountLeft;

    // record the actual repaid amount for event
    uint256 totalRepaid = 0;

    // (1) Repay interest first
    IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), repayInterestAmt);
    // update position
    position.normalizedDebt -= BrokerMath.normalizeBorrowAmount(repayInterestAmt, rate);
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
          BrokerMath.normalizeBorrowAmount(principalRepaid, rate)
        );
        totalRepaid += principalRepaid;
      }
      // remove position if fully repaid
      if (position.principal == 0) {
        delete dynamicLoanPositions[onBehalf];
      }
    }

    emit DynamicLoanPositionRepaid(onBehalf, totalRepaid, position.principal);
  }

  /**
    * @dev Repay a Fixed loan position
    * @notice repay interest first then principal, repay amount must larger than interest
    * @param amount The amount to repay
    * @param posId The ID of the fixed position to repay
    * @param onBehalf The address of the user whose position to repay
   */
  function repay(uint256 amount, uint256 posId, address onBehalf) external override marketIdSet whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    require(onBehalf != address(0), "broker/zero-address");
    address user = msg.sender;

    // fetch position (will revert if not found)
    FixedLoanPosition memory position = _getFixedPositionByPosId(onBehalf, posId);
    // remaining principal before repayment
    uint256 remainingPrincipal = position.principal - position.repaidPrincipal;
    // get outstanding accrued interest
    uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(position) - position.repaidInterest;
    
    // initialize repay amounts
    uint256 repayInterestAmt = amount < accruedInterest ? amount : accruedInterest;
    uint256 repayPrincipalAmt = UtilsLib.min(amount - repayInterestAmt, remainingPrincipal);

    // repay interest first, it might be zero if user just repaid before
    if (repayInterestAmt > 0) {
      IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), repayInterestAmt);
      // update repaid interest amount
      position.repaidInterest += repayInterestAmt;
      // supply interest into vault as revenue
      _supplyToMoolahVault(repayInterestAmt);
    }

    // then repay principal if there is any amount left
    if (repayPrincipalAmt > 0) {
      // ----- penalty
      // check penalty if user is repaying before expiration
      uint256 penalty = _getPenaltyForFixedPosition(position, repayPrincipalAmt);
      // supply penalty into vault as revenue
      if (penalty > 0) {
        IERC20(LOAN_TOKEN).safeTransferFrom(user, address(this), penalty);
        repayPrincipalAmt -= penalty;
        _supplyToMoolahVault(penalty);
      }

      // the rest will be used to repay partially
      if (repayPrincipalAmt > 0) {
        uint256 budget = UtilsLib.min(repayPrincipalAmt, remainingPrincipal);
        uint256 principalRepaid = _repayToMoolah(user, onBehalf, budget);
        position.repaidPrincipal += principalRepaid;
      }
    }

    // post repayment
    if (position.repaidPrincipal >= position.principal) {
      // removes it from user's fixed positions
      _removeFixedPositionByPosId(onBehalf, posId);
    } else {
      // update position
      _updateFixedPosition(onBehalf, position);
    }

    // emit event
    emit RepaidFixedLoanPosition(
      onBehalf,
      position.principal,
      position.start,
      position.end,
      position.apr,
      position.repaidPrincipal,
      position.repaidPrincipal >= position.principal
    );
  }

  /**
    * @dev Convert a portion of or the entire dynamic loan position to a fixed loan position
    * @param amount The amount to convert from dynamic to fixed
    * @param termId The ID of the fixed term to use
   */
  function convertDynamicToFixed(uint256 amount, uint256 termId) external override marketIdSet whenNotPaused nonReentrant {
    require(amount > 0, "broker/zero-amount");
    address user = msg.sender;
    DynamicLoanPosition storage position = dynamicLoanPositions[user];
    require(position.principal >= amount, "broker/insufficient-dynamic-principal");
    require(fixedLoanPositions[user].length < maxFixedLoanPositions, "broker/exceed-max-fixed-positions");

    // accrue current rate so normalized debt reflects the latest interest
    uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    uint256 outstandingInterest = actualDebt > position.principal ? actualDebt - position.principal : 0;

    // allocate proportional share of accrued interest to the amount being converted
    uint256 interestShare = 0;
    if (outstandingInterest > 0) {
      interestShare = BrokerMath.mulDivFlooring(outstandingInterest, amount, position.principal);
    }

    uint256 convertedDebt = amount + interestShare;
    if (convertedDebt > 0) {
      uint256 normalizedDebtDelta = BrokerMath.normalizeBorrowAmount(convertedDebt, rate);
      position.normalizedDebt = position.normalizedDebt.zeroFloorSub(normalizedDebtDelta);
    }

    position.principal -= amount;
    if (position.principal == 0 && position.normalizedDebt == 0) {
      delete dynamicLoanPositions[user];
    }

    FixedTermAndRate memory term = _getTermById(termId);
    uint256 start = block.timestamp;
    uint256 end = start + term.duration;

    fixedLoanPositions[user].push(FixedLoanPosition({
      posId: fixedPosUuid,
      principal: convertedDebt,
      apr: term.apr,
      start: start,
      end: end,
      repaidInterest: 0,
      repaidPrincipal: 0
    }));
    fixedPosUuid++;

    emit FixedLoanPositionCreated(user, convertedDebt, start, end, term.apr, termId);
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
  function liquidate(Id id, address user) external override onlyMoolah marketIdSet whenNotPaused nonReentrant {
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
    uint256 totalDebtAtBroker = BrokerMath.getTotalDebt(fixedPositions, dynamicPosition, rate);
    // [2] calculate actual debt at Moolah after liquidation
    Market memory market = MOOLAH.market(id);
    Position memory mPos = MOOLAH.position(id, user);
    // thats how much user borrowed from Moolah (0% interest, should = total principal at LendingBroker)
    // after liquidation, this will be the new debt amount (partial of collateral has been liquidated)
    uint256 debtAtMoolah = uint256(mPos.borrowShares).toAssetsUp(
      market.totalBorrowAssets,
      market.totalBorrowShares
    );
    // debt at broker > debt at moolah, we need to deduct the diff from positions
    uint256 principalToDeduct = totalDebtAtBroker.zeroFloorSub(debtAtMoolah);
    if (principalToDeduct == 0) return;
    // deduct from dynamic position and returns the leftover assets to deduct
    principalToDeduct = _deductDynamicPositionDebt(dynamicPosition, principalToDeduct, rate);
    // deduct from fixed positions
    if (principalToDeduct > 0 && fixedPositions.length > 0) {
      // sort fixed positions from earliest end time to latest, filter out fully repaid positions
      // positions with earlier end time will be deducted first
      FixedLoanPosition[] memory sorted = _sortAndFilterFixedPositions(fixedPositions);
      if (sorted.length > 0) {
        _deductFixedPositionsDebt(user, sorted, principalToDeduct);
      }
    }
    // emit event
    emit Liquidated(user, totalDebtAtBroker.zeroFloorSub(debtAtMoolah));
  }

  /**
   * @dev sorting by end time ascending and filter out fully repaid positions
   *      - this is a simple insertion sort, gas cost is O(n^2) in worst case,
   *      - works well for small arrays as user's number of fixed positions is limited
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
        uint256 j = count;
        while (j > 0) {
          FixedLoanPosition memory prev = filtered[j - 1];
          if (prev.end <= p.end) {
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
    // get actual debt
    uint256 actualDebt = BrokerMath.denormalizeBorrowAmount(position.normalizedDebt, rate);
    if (actualDebt == 0) return principalToDeduct;

    uint256 outstandingInterest = actualDebt > position.principal
      ? actualDebt - position.principal
      : 0;

    // clear as much accrued interest as possible
    uint256 interestPaid = UtilsLib.min(outstandingInterest, principalToDeduct);
    if (interestPaid > 0) {
      position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
        BrokerMath.normalizeBorrowAmount(interestPaid, rate)
      );
      principalToDeduct -= interestPaid;
    }

    // reduce principal with whatever is left
    uint256 principalPaid = UtilsLib.min(position.principal, principalToDeduct);
    if (principalPaid > 0) {
      position.principal -= principalPaid;
      position.normalizedDebt = position.normalizedDebt.zeroFloorSub(
        BrokerMath.normalizeBorrowAmount(principalPaid, rate)
      );
      principalToDeduct -= principalPaid;
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
      if (principalToDeduct == 0) break;
      FixedLoanPosition memory p = sortedFixedPositions[i];
      // remaining principal before repayment
      uint256 remainingPrincipal = p.principal - p.repaidPrincipal;
      // get accrued interest from LAST REPAID TIME to NOW
      uint256 accruedInterest = BrokerMath.getAccruedInterestForFixedPosition(p) - p.repaidInterest;

      // initialize repay amounts
      uint256 repayInterestAmt = principalToDeduct < accruedInterest ? principalToDeduct : accruedInterest;
      uint256 repayPrincipalAmt = UtilsLib.min(principalToDeduct - repayInterestAmt, remainingPrincipal);

      // repay interest first, it might be zero if user just repaid before
      if (repayInterestAmt > 0) {
        // update repaid interest amount
        p.repaidInterest += repayInterestAmt;
        // supply interest into vault as revenue
        principalToDeduct -= repayInterestAmt;
      }

      // then repay principal if there is any amount left
      if (repayPrincipalAmt > 0) {
        // ----- penalty
        // check penalty if user is repaying before expiration
        uint256 penalty = _getPenaltyForFixedPosition(p, repayPrincipalAmt);
        // supply penalty into vault as revenue
        if (penalty > 0) {
          principalToDeduct -= penalty;
        }

        // the rest will be used to repay partially
        uint256 actualRepaidPrincipal = principalToDeduct > repayPrincipalAmt ? repayPrincipalAmt : principalToDeduct;
        p.repaidPrincipal += actualRepaidPrincipal;
        principalToDeduct -= actualRepaidPrincipal;
      }

      // post repayment
      if (p.repaidPrincipal >= p.principal) {
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
  function peek(address token, address user) external override marketIdSet view returns (uint256 price) {
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
      // in case there is no collaterals
      if (_position.collateral == 0) {
        return collateralPrice;
      }
      // get market info
      Market memory _market = MOOLAH.market(MARKET_ID);
      // convert shares to borrowed amount (Moolah's debt)
      uint256 debtAtMoolah = uint256(_position.borrowShares).toAssetsUp(
        _market.totalBorrowAssets,
        _market.totalBorrowShares
      );
      // get decimal places
      uint8 collateralDecimals = IERC20Metadata(COLLATERAL_TOKEN).decimals();
      uint8 loanDecimals = IERC20Metadata(LOAN_TOKEN).decimals();
      // calculate manipulated price
      uint256 deltaDebt = debtAtBroker > debtAtMoolah ? (debtAtBroker - debtAtMoolah) : 0;
      // Convert (brokerDebt − moolahDebt) per unit collateral into an 8‑decimal price.
      // deltaDebt is in loan token units (10^loanDecimals); collateral is in 10^collateralDecimals.
      // Scale: ceil(deltaDebt * 10^(8 + collateralDecimals) / (collateral * 10^loanDecimals)).
      // 10^(collateralDecimals) cancels collateral units; 10^8 sets price precision.
      // Ceiling rounding avoids under‑deduction (more conservative).
      uint256 deduction = BrokerMath.mulDivCeiling(
        deltaDebt,
        10 ** (8 + uint256(collateralDecimals)),
        _position.collateral * (10 ** uint256(loanDecimals))
      );
      price = deduction >= collateralPrice ? 0 : (collateralPrice - deduction);
      return price;
    }
    revert("Broker/unsupported-token");
  }

  /**
   * @dev Get all fixed loan positions of a user
   * @param user The address of the user
   * @return An array of FixedLoanPosition structs
   */
  function userFixedPositions(address user) external view returns (FixedLoanPosition[] memory) {
    return fixedLoanPositions[user];
  }

  /**
   * @dev Get the dynamic loan position of a user
   * @param user The address of the user
   * @return The DynamicLoanPosition struct
   */
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
  marketIdSet
  onlyRole(BOT) {
    require(posIds.length > 0, "Broker/zero-positions");
    // the additional principal will be add into the dynamic position
    uint256 _principal = 0;
    uint256 _interest = 0;
    // calculate principal to be refinanced one by one
    for (uint256 i = 0; i < posIds.length; i++) {
      uint256 posId = posIds[i];
      // fetch fixed position and make sure it's matured
      FixedLoanPosition memory position = _getFixedPositionByPosId(user, posId);
      require(block.timestamp >= position.end, "Broker/position-not-expired");
      // Debt of a fixed loan position consist of (1) and (2)
      // (1) net principal
      _principal += position.principal - position.repaidPrincipal;
      // (2) get outstanding interest
      _interest += _getAccruedInterestForFixedPosition(position) - position.repaidInterest;
      // remove the fixed position
      _removeFixedPositionByPosId(user, posId);
    }
    if (_principal > 0) {
      // get updated rate
      uint256 rate = IRateCalculator(rateCalculator).accrueRate(address(this));
      // calc. normalized debt (principal + interest)
      uint256 normalizedDebt = BrokerMath.normalizeBorrowAmount(_principal + _interest, rate);
      // update user's dynamic position
      DynamicLoanPosition storage position = dynamicLoanPositions[user];
      position.principal += _principal;
      position.normalizedDebt += normalizedDebt;
      // emit the same event as borrow with dynamic position
      emit DynamicLoanPositionBorrowed(user, _principal, position.principal);
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
   * @param payer The address of the user who pays for the repayment
   * @param onBehalf The address of the user to repay on behalf of
   * @param amount The amount to repay
   */
  function _repayToMoolah(address payer, address onBehalf, uint256 amount) 
  internal
  returns (uint256 assetsRepaid) {
    if (amount == 0) return 0;

    IERC20(LOAN_TOKEN).safeTransferFrom(payer, address(this), amount);
    IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), amount);

    Market memory market = MOOLAH.market(MARKET_ID);
    Position memory pos = MOOLAH.position(MARKET_ID, onBehalf);
    // convert amount to shares
    uint256 amountShares = amount.toSharesDown(
      market.totalBorrowAssets,
      market.totalBorrowShares
    );
    bool repayByShares = amountShares >= pos.borrowShares;
    // for the last bit of repayment
    // using `shares` to ensure full repayment
    (assetsRepaid, /* sharesRepaid */) = MOOLAH.repay(
      _getMarketParams(MARKET_ID),
      repayByShares ? 0 : amount,
      repayByShares ? pos.borrowShares : 0,
      onBehalf,
      ""
    );
    // refund any excess amount to payer
    if (amount > assetsRepaid ) {
      IERC20(LOAN_TOKEN).safeTransfer(payer, amount - assetsRepaid);
    }
  }

  /**
   * @dev Supply an amount of interest to Moolah
   * @param interest The amount of interest to supply
   */
  function _supplyToMoolahVault(uint256 interest) internal {
    if (interest > 0) {
      // approve to Moolah
      IERC20(LOAN_TOKEN).safeIncreaseAllowance(address(MOOLAH), interest);
      // supply interest into vault as revenue
      MOOLAH.supply(
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
  function _removeFixedPositionByPosId(address user, uint256 posId) internal {
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
    require(maxFixedLoanPositions != maxPositions, "broker/same-value-provided");
    uint256 oldMaxFixedLoanPositions = maxFixedLoanPositions;
    maxFixedLoanPositions = maxPositions;
    emit MaxFixedLoanPositionsUpdated(oldMaxFixedLoanPositions, maxPositions);
  }

  /// @dev only callable by the DEFAULT_ADMIN_ROLE (must be a TimeLock contract)
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

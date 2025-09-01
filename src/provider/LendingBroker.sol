// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IProvider } from "./interfaces/IProvider.sol";
import { IBroker, FixedLoanPosition, DynamicLoanPosition, FixedTermAndRate } from "./interfaces/IBroker.sol";

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
  string public BROKER_NAME;

  
  // ------- State variables -------

  // --- Dynamic rate loan
  // user => dynamic loan position
  mapping(address => DynamicLoanPosition) public dynamicLoanPositions;
  // the rate factor calculator for dynamic positions
  address public dynamicDutyCalculator;
  // latest rate factor
  uint256 public duty;
  // timestamp of last duty calculation
  uint256 public lastAccrued;

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
   * @param loanToken The address of the loan token
   * @param collateralToken The address of the collateral token
   * @param oracle The address of the oracle
   */
  constructor(
    address moolah,
    address moolahVault,
    address loanToken,
    address collateralToken,
    address oracle
  ) {
    // zero address assert
    require(
      moolah != address(0) && 
      moolahVault != address(0) && 
      loanToken != address(0) && 
      collateralToken != address(0) &&
      oracle != address(0),
      ErrorsLib.ZERO_ADDRESS
    );
    // loanToken cannot be the same as collateralToken
    require(loanToken != collateralToken, ErrorsLib.INCONSISTENT_INPUT);
    // set addresses
    MOOLAH = IMoolah(moolah);
    MOOLAH_VAULT = IMoolahVault(moolahVault);
    LOAN_TOKEN = loanToken;
    COLLATERAL_TOKEN = collateralToken;
    ORACLE = IOracle(oracle);
    
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
  function borrow(uint256 amount) external override whenNotPaused nonReentrant {

  }

  function borrow(uint256 amount, uint256 termId) external override whenNotPaused nonReentrant {

  }

  function repay(uint256 amount) external override whenNotPaused nonReentrant {

  }

  function repay(uint256 amount, uint256 posIdx) external override whenNotPaused nonReentrant {

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

  ///////////////////////////////////////
  /////       Admin functions       /////
  ///////////////////////////////////////
  function addFixedTermAndRate(uint256 termId, uint256 duration, uint256 apr) external onlyRole(MANAGER) {
    
  }

  function removeFixedTermAndRate(uint256 termId) external onlyRole(MANAGER) {
    
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

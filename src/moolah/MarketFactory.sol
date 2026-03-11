// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { MarketParams, Id, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ILiquidator } from "liquidator/ILiquidator.sol";
import { IListaRevenueDistributor } from "moolah/interfaces/IListaRevenueDistributor.sol";
import { IBuyBack } from "moolah/interfaces/IBuyBack.sol";
import { IListaAutoBuyBack } from "moolah/interfaces/IListaAutoBuyBack.sol";
import { IPublicLiquidator } from "liquidator/IPublicLiquidator.sol";
import { ISmartProvider } from "../provider/interfaces/IProvider.sol";

contract MarketFactory is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using MarketParamsLib for MarketParams;

  IMoolah public immutable moolah;
  ILiquidator public immutable liquidator;
  IListaRevenueDistributor public immutable revenueDistributor;
  IBuyBack public immutable buyBack;
  IListaAutoBuyBack public immutable autoBuyBack;
  IPublicLiquidator public immutable publicLiquidator;
  address public immutable WBNB;
  address public immutable sliBNB;
  address public immutable BNBProvider;
  address public immutable slisBNBProvider;

  bytes32 public constant OPERATOR = keccak256("OPERATOR");

  /**
   * @dev constructor to set immutable variables
   * @param _moolah The address of the Moolah contract
   * @param _liquidator The address of the Liquidator contract
   * @param _publicLiquidator The address of the PublicLiquidator contract
   * @param _revenueDistributor The address of the RevenueDistributor contract
   * @param _buyBack The address of the BuyBack contract
   * @param _autoBuyBack The address of the AutoBuyBack contract
   * @param _WBNB The address of the WBNB token
   * @param _sliBNB The address of the sliBNB token
   * @param _BNBProvider The address of the BNB provider
   * @param _slisBNBProvider The address of the slisBNB provider
   */
  constructor(
    address _moolah,
    address _liquidator,
    address _publicLiquidator,
    address _revenueDistributor,
    address _buyBack,
    address _autoBuyBack,
    address _WBNB,
    address _sliBNB,
    address _BNBProvider,
    address _slisBNBProvider
  ) {
    // sanity check for constructor arguments
    require(_moolah != address(0), "ZeroAddress");
    require(_liquidator != address(0), "ZeroAddress");
    require(_publicLiquidator != address(0), "ZeroAddress");
    require(_revenueDistributor != address(0), "ZeroAddress");
    require(_buyBack != address(0), "ZeroAddress");
    require(_autoBuyBack != address(0), "ZeroAddress");
    require(_WBNB != address(0), "ZeroAddress");
    require(_sliBNB != address(0), "ZeroAddress");
    require(_BNBProvider != address(0), "ZeroAddress");
    require(_slisBNBProvider != address(0), "ZeroAddress");
    // set immutable variables
    moolah = IMoolah(_moolah);
    liquidator = ILiquidator(_liquidator);
    publicLiquidator = IPublicLiquidator(_publicLiquidator);
    revenueDistributor = IListaRevenueDistributor(_revenueDistributor);
    buyBack = IBuyBack(_buyBack);
    autoBuyBack = IListaAutoBuyBack(_autoBuyBack);
    WBNB = _WBNB;
    sliBNB = _sliBNB;
    BNBProvider = _BNBProvider;
    slisBNBProvider = _slisBNBProvider;

    _disableInitializers();
  }

  /**
   * @dev Initializes the contract with the given addresses
   * @param admin The address of the admin role
   * @param operator The address of the operator role
   */
  function initialize(address admin, address operator) public initializer {
    require(admin != address(0) && operator != address(0), "ZeroAddress");
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(OPERATOR, operator);
  }

  /**
   * @dev Creates new markets with the given parameters and configures the related contracts
   * @param params An array of MarketParams for the markets to be created
   * @param liquidatorWhitelist An array of address arrays for the liquidation whitelist of each market
   * @param supplyWhitelist An array of address arrays for the supply whitelist of each market
   * @param liquidatorMarketWhitelist An array of booleans indicating whether to whitelist the market in the liquidator for each market
   * @param liquidatorSmartProviders An array of booleans indicating whether the market is a smart collateral market that requires special provider configuration for each market
   */
  function batchCreateMarkets(
    MarketParams[] calldata params,
    address[][] calldata liquidatorWhitelist,
    address[][] calldata supplyWhitelist,
    bool[] calldata liquidatorMarketWhitelist,
    bool[] calldata liquidatorSmartProviders
  ) external onlyRole(OPERATOR) {
    require(
      params.length == liquidatorWhitelist.length &&
        params.length == supplyWhitelist.length &&
        params.length == liquidatorMarketWhitelist.length &&
        params.length == liquidatorSmartProviders.length,
      "array length mismatch"
    );

    for (uint256 i = 0; i < params.length; i++) {
      _createMarket(
        params[i],
        liquidatorWhitelist[i],
        supplyWhitelist[i],
        liquidatorMarketWhitelist[i],
        liquidatorSmartProviders[i]
      );
    }
  }

  /**
   * @dev Creates a new market with the given parameters and configures the related contracts
   * @param param The MarketParams for the market to be created
   * @param liquidatorWhitelist An array of addresses for the liquidation whitelist of the market
   * @param supplyWhitelist An array of addresses for the supply whitelist of the market
   * @param liquidatorMarketWhitelist A boolean indicating whether to whitelist the market in the liquidator
   * @param liquidatorSmartProvider A boolean indicating whether the market is a smart collateral market that requires special provider configuration
   */
  function createMarket(
    MarketParams calldata param,
    address[] calldata liquidatorWhitelist,
    address[] calldata supplyWhitelist,
    bool liquidatorMarketWhitelist,
    bool liquidatorSmartProvider
  ) external onlyRole(OPERATOR) {
    _createMarket(param, liquidatorWhitelist, supplyWhitelist, liquidatorMarketWhitelist, liquidatorSmartProvider);
  }

  function _createMarket(
    MarketParams memory param,
    address[] memory liquidatorWhitelist,
    address[] memory supplyWhitelist,
    bool liquidatorMarketWhitelist,
    bool liquidatorSmartProvider
  ) private {
    Id id = param.id();
    MarketParams memory p = moolah.idToMarketParams(id);
    if (p.loanToken != address(0)) {
      revert("Market already exists");
    }
    // moolah create market
    moolah.createMarket(param);
    // moolah set liquidation whitelist
    if (liquidatorWhitelist.length > 0) {
      Id[] memory ids = new Id[](1);
      ids[0] = id;
      address[][] memory whitelist = new address[][](1);
      whitelist[0] = liquidatorWhitelist;
      moolah.batchToggleLiquidationWhitelist(ids, whitelist, true);
    }
    // liquidator set market whitelist
    if (liquidatorMarketWhitelist) {
      liquidator.setMarketWhitelist(Id.unwrap(id), true);
    }
    // liquidator set token whitelist
    if (!liquidator.tokenWhitelist(param.loanToken)) {
      liquidator.setTokenWhitelist(param.loanToken, true);
    }
    if (!liquidator.tokenWhitelist(param.collateralToken)) {
      liquidator.setTokenWhitelist(param.collateralToken, true);
    }
    // revenue distributor set token whitelist
    if (!revenueDistributor.tokenWhitelist(param.loanToken)) {
      address[] memory tokens = new address[](1);
      tokens[0] = param.loanToken;
      revenueDistributor.addTokensToWhitelist(tokens);
    }
    // buyback set token whitelist
    if (!buyBack.tokenInWhitelist(param.loanToken)) {
      buyBack.addTokenInWhitelist(param.loanToken);
    }
    // auto buyback set token whitelist
    if (!autoBuyBack.tokenWhitelist(param.loanToken)) {
      autoBuyBack.setTokenWhitelist(param.loanToken, true);
    }
    // set BNBProvider for BNB markets
    if (param.loanToken == WBNB || param.collateralToken == WBNB) {
      moolah.setProvider(id, BNBProvider, true);
    }
    // set slisBNBProvider for sliBNB markets
    if (param.collateralToken == sliBNB) {
      moolah.setProvider(id, slisBNBProvider, true);
    }
    // set supply whitelist
    if (supplyWhitelist.length > 0) {
      for (uint256 i = 0; i < supplyWhitelist.length; i++) {
        moolah.setWhiteList(id, supplyWhitelist[i], true);
      }
    }

    // if market is smart collateral
    if (liquidatorSmartProvider) {
      _configSmartProvider(id, param.oracle, param.collateralToken);
    }
  }

  function _configSmartProvider(Id id, address provider, address collateral) private {
    // moolah set provider
    moolah.setProvider(id, provider, true);
    // moolah set flashloan blacklist
    if (!moolah.flashLoanTokenBlacklist(collateral)) {
      moolah.setFlashLoanTokenBlacklist(collateral, true);
    }
    // liquidator and public liquidator set smart provider whitelist
    address[] memory smartProviders = new address[](1);
    smartProviders[0] = provider;
    if (!liquidator.smartProviders(provider)) {
      liquidator.batchSetSmartProviders(smartProviders, true);
    }
    if (!publicLiquidator.smartProviders(provider)) {
      publicLiquidator.batchSetSmartProviders(smartProviders, true);
    }
    // set token whitelist for liquidator if not set
    address token0 = ISmartProvider(provider).token(0);
    address token1 = ISmartProvider(provider).token(1);
    if (!liquidator.tokenWhitelist(token0)) {
      liquidator.setTokenWhitelist(token0, true);
    }
    if (!liquidator.tokenWhitelist(token1)) {
      liquidator.setTokenWhitelist(token1, true);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

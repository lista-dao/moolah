// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { MarketParams, Id, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ILiquidator } from "liquidator/ILiquidator.sol";
import { IListaRevenueDistributor } from "moolah/interfaces/IListaRevenueDistributor.sol";
import { IBuyBack } from "moolah/interfaces/IBuyBack.sol";
import { IListaAutoBuyBack } from "moolah/interfaces/IListaAutoBuyBack.sol";
import { IPublicLiquidator } from "liquidator/IPublicLiquidator.sol";
import { ISmartProvider } from "../provider/interfaces/IProvider.sol";
import { IBroker } from "../broker/interfaces/IBroker.sol";
import { IBrokerLiquidator } from "../liquidator/IBrokerLiquidator.sol";
import { IRateCalculator } from "../broker/interfaces/IRateCalculator.sol";
import { ILiquidationVault } from "../liquidator/ILiquidationVault.sol";
import { IStockOracleSwitch } from "../oracle/interfaces/IStockOracleSwitch.sol";

contract MarketFactory is UUPSUpgradeable, AccessControlEnumerableUpgradeable, PausableUpgradeable {
  using MarketParamsLib for MarketParams;

  struct FixedTermMarketParams {
    address broker;
    address loanToken;
    address collateralToken;
    address irm;
    uint256 lltv;
    uint256 ratePerSecond;
    uint256 maxRatePerSecond;
  }

  IMoolah public immutable moolah;
  ILiquidator public immutable liquidator;
  IListaRevenueDistributor public immutable revenueDistributor;
  IBuyBack public immutable buyBack;
  IListaAutoBuyBack public immutable autoBuyBack;
  IPublicLiquidator public immutable publicLiquidator;
  address public immutable WBNB; // on ETH: WETH
  address public immutable sliBNB; // on ETH: not used (address(0))
  address public immutable BNBProvider; // on ETH: ETHProvider
  address public immutable slisBNBProvider; // on ETH: not used (address(0))
  IRateCalculator public rateCalculator;
  IBrokerLiquidator public brokerLiquidator;
  /// @dev Shared liquidation fund pool. Tokens of every created market are added to its sell/collect
  ///      allow-list. address(0) disables the wiring (chains where the vault is not deployed yet).
  ILiquidationVault public liquidationVault;
  /// @dev Market-hours switch for tokenized stocks. Required only to create a bStock market
  ///      (`stockCollateral = true`); address(0) disables the wiring.
  IStockOracleSwitch public stockOracleSwitch;

  bytes32 public constant OPERATOR = keccak256("OPERATOR");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  event BrokerMarketDeployed(FixedTermMarketParams fixedTermMarketParams, Id marketId, address broker);
  event CommonMarketDeployed(MarketParams marketParams, Id marketId);
  event RateCalculatorUpdated(address indexed oldAddress, address indexed newAddress);
  event BrokerLiquidatorUpdated(address indexed oldAddress, address indexed newAddress);
  event LiquidationVaultUpdated(address indexed oldAddress, address indexed newAddress);
  event StockOracleSwitchUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev constructor to set immutable variables
   * @param _moolah The address of the Moolah contract
   * @param _liquidator The address of the Liquidator contract
   * @param _publicLiquidator The address of the PublicLiquidator contract
   * @param _revenueDistributor The address of the RevenueDistributor contract (on ETH: address(0) if not needed)
   * @param _buyBack The address of the BuyBack contract (on ETH: address(0) if not needed)
   * @param _autoBuyBack The address of the AutoBuyBack contract (on ETH: address(0) if not needed)
   * @param _WBNB The address of the WBNB token (on ETH: WETH address)
   * @param _sliBNB The address of the sliBNB token (on ETH: address(0))
   * @param _BNBProvider The address of the BNB provider (on ETH: ETHProvider)
   * @param _slisBNBProvider The address of the slisBNB provider (on ETH: address(0))
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
    require(_WBNB != address(0), "ZeroAddress");
    require(_BNBProvider != address(0), "ZeroAddress");
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
  function initialize(address admin, address operator, address pauser) public initializer {
    require(admin != address(0), "ZeroAddress");
    require(operator != address(0), "ZeroAddress");
    require(pauser != address(0), "ZeroAddress");
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(OPERATOR, operator);
    _grantRole(PAUSER, pauser);
  }

  /**
   * @dev Creates new markets with the given parameters and configures the related contracts
   * @param params An array of MarketParams for the markets to be created
   * @param liquidatorWhitelist An array of address arrays for the liquidation whitelist of each market
   * @param supplyWhitelist An array of address arrays for the supply whitelist of each market
   * @param liquidatorMarketWhitelist An array of booleans indicating whether to whitelist the market in the liquidator for each market
   * @param liquidatorSmartProviders An array of booleans indicating whether the market is a smart collateral market that requires special provider configuration for each market
   * @param stockCollaterals An array of booleans indicating whether the collateral token is a tokenized stock (bStock) that must be registered in the StockOracleSwitch for each market
   */
  function batchCreateMarkets(
    MarketParams[] calldata params,
    address[][] calldata liquidatorWhitelist,
    address[][] calldata supplyWhitelist,
    bool[] calldata liquidatorMarketWhitelist,
    bool[] calldata liquidatorSmartProviders,
    bool[] calldata stockCollaterals
  ) external onlyRole(OPERATOR) {
    require(params.length > 0, "empty market params");
    require(
      params.length == liquidatorWhitelist.length &&
        params.length == supplyWhitelist.length &&
        params.length == liquidatorMarketWhitelist.length &&
        params.length == liquidatorSmartProviders.length &&
        params.length == stockCollaterals.length,
      "array length mismatch"
    );

    for (uint256 i = 0; i < params.length; i++) {
      _createMarket(
        params[i],
        liquidatorWhitelist[i],
        supplyWhitelist[i],
        liquidatorMarketWhitelist[i],
        liquidatorSmartProviders[i],
        stockCollaterals[i]
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
   * @param stockCollateral A boolean indicating whether the collateral token is a tokenized stock (bStock) that must be registered in the StockOracleSwitch
   */
  function createMarket(
    MarketParams calldata param,
    address[] calldata liquidatorWhitelist,
    address[] calldata supplyWhitelist,
    bool liquidatorMarketWhitelist,
    bool liquidatorSmartProvider,
    bool stockCollateral
  ) external onlyRole(OPERATOR) {
    _createMarket(
      param,
      liquidatorWhitelist,
      supplyWhitelist,
      liquidatorMarketWhitelist,
      liquidatorSmartProvider,
      stockCollateral
    );
  }

  /**
   * @dev Creates new fixed term markets with the given parameters and configures the related contracts
   * @param params An array of FixedTermMarketParams for the markets to be created
   */
  function batchCreateFixedTermMarkets(
    FixedTermMarketParams[] calldata params
  ) external onlyRole(OPERATOR) returns (Id[] memory) {
    require(params.length > 0, "empty market params");

    Id[] memory ids = new Id[](params.length);
    for (uint256 i = 0; i < params.length; i++) {
      ids[i] = _createFixedTermMarket(params[i]);
    }
    return ids;
  }

  /**
   * @dev Creates a new fixed term market with the given parameters and configures the related contracts
   * @param param The FixedTermMarketParams for the market to be created
   */
  function createFixedTermMarket(FixedTermMarketParams calldata param) external onlyRole(OPERATOR) returns (Id) {
    return _createFixedTermMarket(param);
  }

  function _createMarket(
    MarketParams memory param,
    address[] memory liquidatorWhitelist,
    address[] memory supplyWhitelist,
    bool liquidatorMarketWhitelist,
    bool liquidatorSmartProvider,
    bool stockCollateral
  ) private whenNotPaused {
    Id id = param.id();
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
    // token whitelist across the liquidation suite (Liquidator / BrokerLiquidator / LiquidationVault).
    // A smart-collateral LP is excluded from the vault only: the vault cannot sell it, so it is
    // reflow-blacklisted in _configSmartProvider and only its underlying pair legs are vault-whitelisted.
    // Whitelisting the LP there would also open the BOT collect* path for it.
    _whitelistToken(param.loanToken, true);
    _whitelistToken(param.collateralToken, !liquidatorSmartProvider);
    // revenue distributor set token whitelist
    if (address(revenueDistributor) != address(0) && !revenueDistributor.tokenWhitelist(param.loanToken)) {
      address[] memory tokens = new address[](1);
      tokens[0] = param.loanToken;
      revenueDistributor.addTokensToWhitelist(tokens);
    }
    // buyback set token whitelist
    if (address(buyBack) != address(0) && !buyBack.tokenInWhitelist(param.loanToken)) {
      buyBack.addTokenInWhitelist(param.loanToken);
    }
    // auto buyback set token whitelist
    if (address(autoBuyBack) != address(0) && !autoBuyBack.tokenWhitelist(param.loanToken)) {
      autoBuyBack.setTokenWhitelist(param.loanToken, true);
    }
    // set BNBProvider for BNB markets
    if (param.loanToken == WBNB || param.collateralToken == WBNB) {
      moolah.setProvider(id, BNBProvider, true);
    }
    // set slisBNBProvider for sliBNB markets
    if (slisBNBProvider != address(0) && param.collateralToken == sliBNB) {
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

    // if collateral is a tokenized stock, register it in the market-hours switch. setStock also opens
    // the stock; it stays gated by the switch's global market-hours flag, which MANAGER owns.
    if (stockCollateral) {
      require(address(stockOracleSwitch) != address(0), "StockOracleSwitch not set");
      if (!stockOracleSwitch.registered(param.collateralToken)) {
        stockOracleSwitch.setStock(param.collateralToken, true);
      }
    }

    emit CommonMarketDeployed(param, id);
  }

  function _createFixedTermMarket(FixedTermMarketParams memory param) private whenNotPaused returns (Id) {
    IBroker broker = IBroker(param.broker);
    require(param.broker != address(0), "Zero broker address");
    require(address(rateCalculator) != address(0), "RateCalculator not set");
    require(address(brokerLiquidator) != address(0), "BrokerLiquidator not set");

    // moolah create market
    MarketParams memory marketParam = MarketParams({
      loanToken: param.loanToken,
      collateralToken: param.collateralToken,
      oracle: param.broker,
      irm: param.irm,
      lltv: param.lltv
    });
    moolah.createMarket(marketParam);
    Id id = marketParam.id();

    // moolah set liquidation whitelist
    Id[] memory ids = new Id[](1);
    ids[0] = id;
    address[][] memory whitelist = new address[][](1);
    whitelist[0] = new address[](1);
    whitelist[0][0] = param.broker;
    moolah.batchToggleLiquidationWhitelist(ids, whitelist, true);

    // broker set market id
    broker.setMarketId(id);

    // broker set liquidator whitelist
    broker.toggleLiquidationWhitelist(address(brokerLiquidator), true);

    // set slisBNBProvider for sliBNB markets
    if (slisBNBProvider != address(0) && param.collateralToken == sliBNB) {
      moolah.setProvider(id, slisBNBProvider, true);
    }

    // moolah set broker
    moolah.setMarketBroker(id, param.broker, true);

    // rate calculator register broker
    rateCalculator.registerBroker(param.broker, param.ratePerSecond, param.maxRatePerSecond);

    // token whitelist across the liquidation suite (Liquidator / BrokerLiquidator / LiquidationVault)
    _whitelistToken(param.loanToken, true);
    _whitelistToken(param.collateralToken, true);

    // broker liquidator set market whitelist
    brokerLiquidator.setMarketToBroker(Id.unwrap(id), param.broker, true);

    emit BrokerMarketDeployed(param, id, param.broker);
    return id;
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
    if (address(brokerLiquidator) != address(0) && !brokerLiquidator.smartProviders(provider)) {
      brokerLiquidator.batchSetSmartProviders(smartProviders, true);
    }
    // the underlying pair legs are what actually gets sold after a smart-collateral liquidation, so
    // they are whitelisted on the whole suite. A native leg surfaces here as BNB_ADDRESS and is
    // whitelisted like any other token, which is what collectETH / sellBNB require.
    address token0 = ISmartProvider(provider).token(0);
    address token1 = ISmartProvider(provider).token(1);
    _whitelistToken(token0, true);
    _whitelistToken(token1, true);
    // blacklist the LP collateral from reflow on every liquidator that reflows into the vault: a
    // wrong-entry plain liquidate must not push un-sellable LP into the vault. It stays in the
    // liquidator, recoverable via redeemSmartCollateral. PublicLiquidator has no reflow path.
    if (!liquidator.reflowBlacklist(collateral)) {
      liquidator.setReflowBlacklist(collateral, true);
    }
    if (address(brokerLiquidator) != address(0) && !brokerLiquidator.reflowBlacklist(collateral)) {
      brokerLiquidator.setReflowBlacklist(collateral, true);
    }
  }

  /// @dev Whitelist `token` on every contract that can hold or sell it during a liquidation: the
  ///      Liquidator, the BrokerLiquidator and — when `includeVault` — the LiquidationVault. The
  ///      latter two are skipped while unwired (address(0)). Every branch reads the current status
  ///      first because these setters reject a no-op status change.
  /// @param includeVault false only for a smart-collateral LP, which the vault must never hold.
  function _whitelistToken(address token, bool includeVault) private {
    if (!liquidator.tokenWhitelist(token)) {
      liquidator.setTokenWhitelist(token, true);
    }
    if (address(brokerLiquidator) != address(0) && !brokerLiquidator.tokenWhitelist(token)) {
      brokerLiquidator.setTokenWhitelist(token, true);
    }
    if (includeVault && address(liquidationVault) != address(0) && !liquidationVault.tokenWhitelist(token)) {
      liquidationVault.setTokenWhitelist(token, true);
    }
  }

  /**
   * @dev Set the rate calculator address
   * @param _rateCalculator The address of the rate calculator contract
   */
  function setRateCalculator(address _rateCalculator) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_rateCalculator != address(0), "ZeroAddress");
    emit RateCalculatorUpdated(address(rateCalculator), _rateCalculator);
    rateCalculator = IRateCalculator(_rateCalculator);
  }

  /**
   * @dev Set the broker liquidator address
   * @param _brokerLiquidator The address of the broker liquidator contract
   */
  function setBrokerLiquidator(address _brokerLiquidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_brokerLiquidator != address(0), "ZeroAddress");
    emit BrokerLiquidatorUpdated(address(brokerLiquidator), _brokerLiquidator);
    brokerLiquidator = IBrokerLiquidator(_brokerLiquidator);
  }

  /**
   * @dev Set the liquidation vault address
   * @param _liquidationVault The address of the liquidation vault contract
   */
  function setLiquidationVault(address _liquidationVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_liquidationVault != address(0), "ZeroAddress");
    emit LiquidationVaultUpdated(address(liquidationVault), _liquidationVault);
    liquidationVault = ILiquidationVault(_liquidationVault);
  }

  /**
   * @dev Set the stock oracle switch address
   * @param _stockOracleSwitch The address of the stock oracle switch contract
   */
  function setStockOracleSwitch(address _stockOracleSwitch) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_stockOracleSwitch != address(0), "ZeroAddress");
    emit StockOracleSwitchUpdated(address(stockOracleSwitch), _stockOracleSwitch);
    stockOracleSwitch = IStockOracleSwitch(_stockOracleSwitch);
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
  function unpause() external onlyRole(OPERATOR) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

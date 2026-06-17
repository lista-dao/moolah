// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";

interface IStockOracleSwitch {
  function isEnabled(address token) external view returns (bool);
}

/// @title StockOracle
/// @notice Moolah {IOracle} for tokenized-stock (bStock) markets.
/// @dev    Two responsibilities, both thin:
///         1. Pricing: delegates to the Lista resilient oracle (Atlas-backed). The bStock's Atlas
///            price feed must be configured into the resilient oracle (`setTokenConfig`) beforehand.
///         2. Market hours: gates "closed" stocks via {StockOracleSwitch}. When a managed stock is
///            closed, `peek` reverts — which blocks borrow / withdrawCollateral / liquidate in Moolah
///            (they consult the price) while leaving supply / repay / withdraw / supplyCollateral usable.
///         Unmanaged tokens (e.g. the loan token USDT, not registered in the switch) pass straight through, ungated.
///
///         The resilient/Atlas feed prices the RAW token (same unit as `balanceOf` and the
///         liquidation swap). bStocks use an ERC-8056 / scaled-UI-amount model where `balanceOf` is the
///         raw amount and a stock split only changes the UI multiplier (balanceOf is unchanged, no rebase).
contract StockOracle is AccessControlEnumerableUpgradeable, UUPSUpgradeable, IOracle {
  /// @dev Lista resilient oracle (Atlas-backed) that prices the loan token and the configured bStocks.
  ///      Settable by MANAGER (e.g. BSC mainnet: 0xf3afD82A4071f272F403dC176916141f44E6c750).
  address public resilientOracle;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // can repoint the switch

  /// @dev market open/closed control
  IStockOracleSwitch public stockSwitch;

  event StockSwitchSet(address indexed stockSwitch);
  event ResilientOracleSet(address indexed resilientOracle);

  error ZeroAddress();
  error StockMarketClosed();
  error AlreadySet();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @param admin            DEFAULT_ADMIN_ROLE holder (upgrade + role admin)
  /// @param manager          MANAGER role (repoint switch / resilient oracle)
  /// @param stockSwitch_     the {StockOracleSwitch} this oracle reads
  /// @param resilientOracle_ the Lista resilient oracle (Atlas-backed) to delegate pricing to
  function initialize(
    address admin,
    address manager,
    address stockSwitch_,
    address resilientOracle_
  ) external initializer {
    require(admin != address(0), ZeroAddress());
    require(manager != address(0), ZeroAddress());
    require(stockSwitch_ != address(0), ZeroAddress());
    require(resilientOracle_ != address(0), ZeroAddress());
    __AccessControl_init();
    __UUPSUpgradeable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    stockSwitch = IStockOracleSwitch(stockSwitch_);
    resilientOracle = resilientOracle_;
  }

  /// @inheritdoc IOracle
  /// @dev Reverts {StockMarketClosed} when the token is a managed stock that is currently closed;
  ///      otherwise delegates the price to the resilient oracle (which holds the Atlas feed).
  function peek(address asset) external view override returns (uint256) {
    if (!stockSwitch.isEnabled(asset)) revert StockMarketClosed();
    return IOracle(resilientOracle).peek(asset);
  }

  /// @inheritdoc IOracle
  function getTokenConfig(address asset) external view override returns (TokenConfig memory) {
    return IOracle(resilientOracle).getTokenConfig(asset);
  }

  /// @notice Repoint the market open/closed switch. MANAGER role.
  function setStockSwitch(address stockSwitch_) external onlyRole(MANAGER) {
    require(stockSwitch_ != address(0), ZeroAddress());
    require(stockSwitch_ != address(stockSwitch), AlreadySet());
    stockSwitch = IStockOracleSwitch(stockSwitch_);
    emit StockSwitchSet(stockSwitch_);
  }

  /// @notice Repoint the resilient oracle used for pricing. MANAGER role.
  function setResilientOracle(address resilientOracle_) external onlyRole(MANAGER) {
    require(resilientOracle_ != address(0), ZeroAddress());
    require(resilientOracle_ != resilientOracle, AlreadySet());
    resilientOracle = resilientOracle_;
    emit ResilientOracleSet(resilientOracle_);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

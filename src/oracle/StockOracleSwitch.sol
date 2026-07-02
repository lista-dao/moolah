// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title StockOracleSwitch
/// @notice Market open/closed control for tokenized stocks (bStocks), consumed by {StockOracle}.
/// @dev    Layers:
///         - `registered` (MANAGER): whether a token is a managed stock. Unregistered tokens are NOT
///           gated (e.g. the loan token USDT) — {StockOracle} passes them straight through.
///         - per-stock `enabled` (BOT): toggled individually via open / close, or in bulk via batchSetStatus.
///         - global market switch `globalEnabled` (MANAGER): the market-hours switch (setGlobal). A
///           registered stock is enabled only while both the global switch and its own flag are on.
///         PAUSER can force the whole market closed in an emergency (globalEnabled = false).
contract StockOracleSwitch is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  bytes32 public constant MANAGER = keccak256("MANAGER"); // register / un-register stocks; global daily switch; admins BOT
  bytes32 public constant BOT = keccak256("BOT"); // per-stock open / close (single + batch)
  bytes32 public constant PAUSER = keccak256("PAUSER"); // emergency force-close

  /// @dev token => is a managed stock. Unregistered (false) => passthrough (never gated).
  mapping(address => bool) public registered;
  /// @dev token => per-stock enabled flag (only meaningful while registered).
  mapping(address => bool) public enabled;
  /// @dev global market switch; true = open. Defaults to false (fail-safe: closed until explicitly opened).
  bool public globalEnabled;

  event StockSet(address indexed token, bool registered);
  event StockEnable(address indexed token, bool enabled);
  event GlobalEnabledSet(bool enabled);

  error ZeroAddress();
  error AlreadySet();
  error NotRegistered();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @param admin   DEFAULT_ADMIN_ROLE holder (upgrade + role admin)
  /// @param manager MANAGER role (register / un-register stocks; global daily switch; admins BOT)
  /// @param bot     BOT role (per-stock open / close, single + batch)
  /// @param pauser  PAUSER role (emergency force-close)
  function initialize(address admin, address manager, address bot, address pauser) external initializer {
    require(admin != address(0), ZeroAddress());
    require(manager != address(0), ZeroAddress());
    require(bot != address(0), ZeroAddress());
    require(pauser != address(0), ZeroAddress());
    __AccessControl_init();
    __UUPSUpgradeable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
    _grantRole(PAUSER, pauser);
    // MANAGER administers the BOT role, so it can grant / revoke BOT via grantRole / revokeRole.
    _setRoleAdmin(BOT, MANAGER);
    // globalEnabled stays false on purpose: market is closed until MANAGER opens it.
  }

  /// @notice Whether `token` is currently enabled (tradable). Unregistered tokens are always enabled (passthrough).
  /// @dev    Consumed by {StockOracle.peek}: a disabled token makes peek revert, which blocks
  ///         borrow / withdrawCollateral / liquidate in Moolah while leaving supply/repay/withdraw working.
  function isEnabled(address token) external view returns (bool) {
    if (!registered[token]) return true; // not a managed stock -> passthrough (always enabled)
    return globalEnabled && enabled[token]; // registered -> enabled only if the market and the stock are on
  }

  /// @notice Register or un-register a managed stock. MANAGER role.
  /// @dev    Registering a stock enables it by default. Un-registering removes the token from managed-stock
  ///         gating entirely: isEnabled then returns true (passthrough), which is NOT the same as closing it.
  ///         Use close() to gate a registered stock without un-registering. While registered, BOT can toggle
  ///         the per-stock flag via open / close.
  function setStock(address token, bool isStock) external onlyRole(MANAGER) {
    require(token != address(0), ZeroAddress());
    require(registered[token] != isStock, AlreadySet());
    registered[token] = isStock;
    enabled[token] = isStock;
    emit StockSet(token, isStock);
    emit StockEnable(token, isStock);
  }

  /// @notice Open a registered stock for trading. BOT role. Only registered stocks can be toggled.
  function open(address token) public onlyRole(BOT) {
    require(token != address(0), ZeroAddress());
    require(registered[token], NotRegistered());
    require(!enabled[token], AlreadySet());
    enabled[token] = true;
    emit StockEnable(token, true);
  }

  /// @notice Close a registered stock. BOT role. Only registered stocks can be toggled.
  function close(address token) public onlyRole(BOT) {
    require(token != address(0), ZeroAddress());
    require(registered[token], NotRegistered());
    require(enabled[token], AlreadySet());
    enabled[token] = false;
    emit StockEnable(token, false);
  }

  /// @notice Bulk per-stock open/close. BOT role. Opens (`status = true`) or closes (`status = false`)
  ///         every token in `tokens` in one call by delegating to {open} / {close}.
  /// @dev    Strict: inherits the {open} / {close} guards, so a token already in the target state
  ///         (AlreadySet) or not registered (NotRegistered) reverts the whole batch.
  function batchSetStatus(address[] calldata tokens, bool status) external onlyRole(BOT) {
    for (uint256 i; i < tokens.length; ++i) {
      if (status) open(tokens[i]);
      else close(tokens[i]);
    }
  }

  /// @notice Toggle the global market switch (daily open/close). MANAGER role.
  function setGlobal(bool open) external onlyRole(MANAGER) {
    require(open != globalEnabled, AlreadySet());
    globalEnabled = open;
    emit GlobalEnabledSet(open);
  }

  /// @notice Emergency: force the whole stock market closed. PAUSER role.
  /// @dev    No AlreadySet guard — always succeeds so it can be invoked unconditionally in an emergency.
  function emergencyClose() external onlyRole(PAUSER) {
    globalEnabled = false;
    emit GlobalEnabledSet(false);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

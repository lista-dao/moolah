// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { ILiquidationVault, ILiquidatorWithdraw } from "./ILiquidationVault.sol";

/// @title LiquidationVault
/// @notice Shared liquidation fund pool. Holds all protocol liquidation reserves and inventory,
///         funds registered liquidators on demand (provideFund), sells inventory with an oracle loss
///         guard (sellToken/sellBNB), and collects residual balances from liquidators (collect*).
///         The vault never approves as an owner, never does an owner transferFrom, and never calls any
///         address outside the `liquidators` registry (swap pairs/routers excepted).
contract LiquidationVault is
  UUPSUpgradeable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  ILiquidationVault
{
  using SafeTransferLib for address;

  string internal constant ZERO_ADDRESS = "zero address";
  error NotRegistered();
  error NotAuthorized();
  error NotWhitelisted();
  error ExceedAmount();
  error NoProfit();
  error SwapFailed();
  error WhitelistSameStatus();
  error OracleZero();
  error OracleLoss();
  error DailyLossExceeded();
  error InvalidParam();

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  /// @dev Denominator for `maxSwapLossBp` — parts-per-million (ppm).
  uint256 public constant BPS_DENOM = 1e6;

  /// @dev Registered liquidators: provideFund allow-list AND collect* target allow-list.
  mapping(address => bool) public liquidators;
  /// @dev Sell allow-list: tokens that may be an in/out leg of sell* and collected by BOT.
  mapping(address => bool) public tokenWhitelist;
  /// @dev Sell allow-list: pairs/routers that may receive the low-level swap call.
  mapping(address => bool) public pairWhitelist;

  /// @dev ResilientOracle used by the sell loss guard; peek() returns 8-decimal USD price.
  address public oracle;
  /// @dev Per-swap loss cap in ppm (BPS_DENOM = 1e6). Default 50_000 = 5%.
  uint256 public maxSwapLossBp;
  /// @dev Per-UTC-day cumulative loss cap, 8-decimal USD. Default 1000e8.
  uint256 public maxDailyLossUsd;
  /// @dev UTC day (block.timestamp / 1 days) the accumulator currently tracks.
  uint256 public dailyLossDay;
  /// @dev Cumulative sell loss (8-decimal USD) recorded so far for `dailyLossDay`.
  uint256 public dailyLossAccum;
  /// @dev Optional revenue collector authorized to withdraw* (funds land on itself). 0 disables it.
  address public revenueCollector;

  event SellToken(
    address pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 actualAmountOut
  );
  event TokenWhitelistChanged(address indexed token, bool added);
  event PairWhitelistChanged(address indexed pair, bool added);
  event OracleChanged(address indexed oracle);
  event MaxSwapLossBpChanged(uint256 bp);
  event MaxDailyLossUsdChanged(uint256 usd8);
  event RevenueCollectorChanged(address indexed revenueCollector);
  event DailyLossAccrued(uint256 indexed day, uint256 loss, uint256 accum);
  event Withdraw(address indexed to, address indexed token, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @dev Initializes the vault. BOT's role admin is MANAGER so hot-key rotation is a
  ///      multisig operation rather than a TimeLock operation.
  /// @param admin DEFAULT_ADMIN_ROLE (TimeLock): role management + UUPS upgrade authorization.
  /// @param manager MANAGER (multisig): config, withdraw*, unpause, registry.
  /// @param pauser PAUSER: emergency one-way pause.
  /// @param bot BOT (ops EOA): sell*/collect*.
  function initialize(address admin, address manager, address pauser, address bot) public initializer {
    require(admin != address(0), ZERO_ADDRESS);
    require(manager != address(0), ZERO_ADDRESS);
    require(pauser != address(0), ZERO_ADDRESS);
    require(bot != address(0), ZERO_ADDRESS);
    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);
    _grantRole(BOT, bot);
    _setRoleAdmin(BOT, MANAGER);

    maxSwapLossBp = 50_000; // 5%
    maxDailyLossUsd = 1000e8; // 1000 USD (8-decimal)
  }

  /// @dev Receives native BNB: liquidator reflow, collectETH proceeds, sellBNB change.
  receive() external payable {}

  // ----------------------------- Funding ----------------------------- //

  /// @inheritdoc ILiquidationVault
  function provideFund(address token, uint256 amount) external whenNotPaused nonReentrant {
    require(liquidators[msg.sender], NotRegistered());
    token.safeTransfer(msg.sender, amount);
    emit FundProvided(msg.sender, token, amount);
  }

  // ----------------------------- Collection ----------------------------- //

  /// @inheritdoc ILiquidationVault
  function collectERC20(address liquidator, address token, uint256 amount) external whenNotPaused nonReentrant {
    _requireBotOrManager();
    require(liquidators[liquidator], NotRegistered());
    // BOT path is restricted to whitelisted tokens (process-held LP/shares/mis-sent tokens stay out of
    // the vault); MANAGER path is the rescue channel for anything else.
    if (!hasRole(MANAGER, msg.sender)) require(tokenWhitelist[token], NotWhitelisted());
    ILiquidatorWithdraw(liquidator).withdrawERC20(token, amount);
    emit FundCollected(liquidator, token, amount);
  }

  /// @inheritdoc ILiquidationVault
  function collectETH(address liquidator, uint256 amount) external whenNotPaused nonReentrant {
    _requireBotOrManager();
    require(liquidators[liquidator], NotRegistered());
    if (!hasRole(MANAGER, msg.sender)) require(tokenWhitelist[BNB_ADDRESS], NotWhitelisted());
    ILiquidatorWithdraw(liquidator).withdrawETH(amount);
    emit FundCollected(liquidator, BNB_ADDRESS, amount);
  }

  // ----------------------------- Selling ----------------------------- //

  /// @dev Sell an ERC20 for another ERC20 via a whitelisted pair. `spender` is the address approved to
  ///      pull tokenIn; it may equal `pair` (single venue) or be a distinct whitelisted router. Both
  ///      `pair` and `spender` must be whitelisted.
  function sellToken(
    address pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external nonReentrant whenNotPaused onlyRole(BOT) {
    require(tokenWhitelist[tokenIn], NotWhitelisted());
    require(tokenWhitelist[tokenOut], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(pairWhitelist[spender], NotWhitelisted());
    require(amountIn > 0, "amountIn zero");

    require(tokenIn.balanceOf(address(this)) >= amountIn, ExceedAmount());

    uint256 beforeTokenIn = tokenIn.balanceOf(address(this));
    uint256 beforeTokenOut = tokenOut.balanceOf(address(this));

    tokenIn.safeApprove(spender, amountIn);
    (bool success, ) = pair.call(swapData);
    require(success, SwapFailed());

    uint256 actualAmountIn = beforeTokenIn - tokenIn.balanceOf(address(this));
    uint256 actualAmountOut = tokenOut.balanceOf(address(this)) - beforeTokenOut;

    require(actualAmountIn <= amountIn, ExceedAmount());
    require(actualAmountOut >= amountOutMin, NoProfit());

    tokenIn.safeApprove(spender, 0);

    _guardSwapLoss(tokenIn, actualAmountIn, tokenOut, actualAmountOut);

    emit SellToken(pair, spender, tokenIn, tokenOut, actualAmountIn, actualAmountOut);
  }

  /// @dev Sell native BNB for an ERC20 via a whitelisted pair.
  function sellBNB(
    address pair,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external nonReentrant whenNotPaused onlyRole(BOT) {
    require(tokenWhitelist[BNB_ADDRESS], NotWhitelisted());
    require(tokenWhitelist[tokenOut], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(amountIn > 0, "amountIn zero");

    require(address(this).balance >= amountIn, ExceedAmount());

    uint256 beforeTokenIn = address(this).balance;
    uint256 beforeTokenOut = tokenOut.balanceOf(address(this));

    (bool success, ) = pair.call{ value: amountIn }(swapData);
    require(success, SwapFailed());

    uint256 actualAmountIn = beforeTokenIn - address(this).balance;
    uint256 actualAmountOut = tokenOut.balanceOf(address(this)) - beforeTokenOut;

    require(actualAmountIn <= amountIn, ExceedAmount());
    require(actualAmountOut >= amountOutMin, NoProfit());

    _guardSwapLoss(BNB_ADDRESS, actualAmountIn, tokenOut, actualAmountOut);

    emit SellToken(pair, pair, BNB_ADDRESS, tokenOut, actualAmountIn, actualAmountOut);
  }

  /// @dev Oracle loss guard. Uses balance-diff actual amounts. Fail-closed on a zero price.
  ///      (1) per-swap cap: valueOut·1e6 >= valueIn·(1e6 - maxSwapLossBp);
  ///      (2) per-UTC-day cumulative loss cap (profit does not offset).
  function _guardSwapLoss(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) private {
    uint256 valueIn = _oracleValue(tokenIn, amountIn);
    uint256 valueOut = _oracleValue(tokenOut, amountOut);

    // per-swap loss cap
    require(valueOut * BPS_DENOM >= valueIn * (BPS_DENOM - maxSwapLossBp), OracleLoss());

    // per-UTC-day cumulative loss cap (profit is not credited)
    uint256 today = block.timestamp / 1 days;
    if (today != dailyLossDay) {
      dailyLossDay = today;
      dailyLossAccum = 0;
    }
    uint256 loss = valueIn > valueOut ? valueIn - valueOut : 0;
    if (loss > 0) {
      uint256 accum = dailyLossAccum + loss;
      require(accum <= maxDailyLossUsd, DailyLossExceeded());
      dailyLossAccum = accum;
      emit DailyLossAccrued(today, loss, accum);
    }
  }

  /// @dev 8-decimal USD value of `amount` of `token`. `dec = 18` for native BNB. peek==0 => revert.
  function _oracleValue(address token, uint256 amount) private view returns (uint256) {
    uint256 price = IOracle(oracle).peek(token); // 8-decimal USD
    require(price > 0, OracleZero());
    uint256 dec = token == BNB_ADDRESS ? 18 : IERC20Metadata(token).decimals();
    return (amount * price) / (10 ** dec);
  }

  // ----------------------------- Withdraw / revenue ----------------------------- //

  /// @dev Withdraw an ERC20 to msg.sender. Gate: MANAGER (wind-down/rebalance) or the registered
  ///      revenueCollector (fee pull). Same selector as ILiquidator so RevenueCollector can call it.
  function withdrawERC20(address token, uint256 amount) external {
    _requireManagerOrRevenueCollector();
    token.safeTransfer(msg.sender, amount);
    emit Withdraw(msg.sender, token, amount);
  }

  /// @dev Withdraw native BNB to msg.sender. Gate as withdrawERC20.
  function withdrawETH(uint256 amount) external {
    _requireManagerOrRevenueCollector();
    msg.sender.safeTransferETH(amount);
    emit Withdraw(msg.sender, BNB_ADDRESS, amount);
  }

  // ----------------------------- Config (MANAGER) ----------------------------- //

  /// @dev Register/deregister a liquidator (provideFund + collect* allow-list).
  function setLiquidator(address liquidator, bool registered) external onlyRole(MANAGER) {
    require(liquidator != address(0), ZERO_ADDRESS);
    liquidators[liquidator] = registered;
    emit LiquidatorSet(liquidator, registered);
  }

  function setTokenWhitelist(address token, bool status) external onlyRole(MANAGER) {
    require(tokenWhitelist[token] != status, WhitelistSameStatus());
    tokenWhitelist[token] = status;
    emit TokenWhitelistChanged(token, status);
  }

  function setPairWhitelist(address pair, bool status) external onlyRole(MANAGER) {
    require(pair != address(0), ZERO_ADDRESS);
    require(pairWhitelist[pair] != status, WhitelistSameStatus());
    pairWhitelist[pair] = status;
    emit PairWhitelistChanged(pair, status);
  }

  function setOracle(address _oracle) external onlyRole(MANAGER) {
    require(_oracle != address(0), ZERO_ADDRESS);
    oracle = _oracle;
    emit OracleChanged(_oracle);
  }

  function setMaxSwapLossBp(uint256 bp) external onlyRole(MANAGER) {
    require(bp <= BPS_DENOM, InvalidParam());
    maxSwapLossBp = bp;
    emit MaxSwapLossBpChanged(bp);
  }

  function setMaxDailyLossUsd(uint256 usd8) external onlyRole(MANAGER) {
    maxDailyLossUsd = usd8;
    emit MaxDailyLossUsdChanged(usd8);
  }

  /// @dev Set the revenue collector. Allows 0 (disable). Non-zero must be a contract.
  function setRevenueCollector(address rc) external onlyRole(MANAGER) {
    if (rc != address(0)) require(rc.code.length > 0, InvalidParam());
    revenueCollector = rc;
    emit RevenueCollectorChanged(rc);
  }

  // ----------------------------- Pause / upgrade ----------------------------- //

  /// @dev One-way emergency pause (PAUSER). Halts provideFund + collect* + sell*.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  // ----------------------------- Internal ----------------------------- //

  function _requireBotOrManager() private view {
    require(hasRole(BOT, msg.sender) || hasRole(MANAGER, msg.sender), NotAuthorized());
  }

  function _requireManagerOrRevenueCollector() private view {
    require(
      hasRole(MANAGER, msg.sender) || (revenueCollector != address(0) && msg.sender == revenueCollector),
      NotAuthorized()
    );
  }
}

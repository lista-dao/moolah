// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IV3Provider } from "../provider/interfaces/IV3Provider.sol";
import "./Interface.sol";

/**
 * @title V3Liquidator
 * @notice Liquidator for Moolah markets whose collateral is a V3Provider LP share token.
 *
 *   Liquidation flows:
 *   1. liquidate()          — pre-funded: caller holds loanToken, receives V3 shares.
 *   2. flashLiquidate()     — callback-based: in onMoolahLiquidate, optionally redeem
 *                             V3 shares → TOKEN0 / TOKEN1, swap to loanToken, repay.
 *   3. redeemV3Shares()     — standalone: redeem shares held by this contract.
 *   4. sellToken/sellBNB()  — swap any token/BNB held by this contract (e.g. post-redeem).
 */
contract V3Liquidator is ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {
  using SafeTransferLib for address;

  /* ──────────────────────────── errors ────────────────────────────── */

  error NoProfit();
  error OnlyMoolah();
  error ExceedAmount();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();

  /* ──────────────────────────── constants ─────────────────────────── */

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /// @dev Virtual address used to represent native BNB in token whitelists.
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @dev BSC wrapped native token — V3Provider unwraps it to native BNB on exit.
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  /* ──────────────────────────── immutables ─────────────────────────── */

  address public immutable MOOLAH;

  /* ──────────────────────────── storage ───────────────────────────── */

  mapping(address => bool) public tokenWhitelist;
  mapping(bytes32 => bool) public marketWhitelist;
  mapping(address => bool) public pairWhitelist;
  /// @dev Whitelisted V3Provider contracts (collateral token = the provider itself).
  mapping(address => bool) public v3Providers;

  /* ──────────────────────────── events ────────────────────────────── */

  event TokenWhitelistChanged(address indexed token, bool status);
  event MarketWhitelistChanged(bytes32 indexed id, bool status);
  event PairWhitelistChanged(address indexed pair, bool status);
  event V3ProviderWhitelistChanged(address indexed provider, bool status);
  event SellToken(
    address indexed pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 actualAmountOut
  );
  event V3Liquidation(
    bytes32 indexed id,
    address indexed v3Provider,
    address indexed borrower,
    uint256 seized,
    uint256 repaid,
    uint256 amount0,
    uint256 amount1
  );

  /* ──────────────────────── callback struct ───────────────────────── */

  /**
   * @dev Passed through Moolah's liquidate callback mechanism.
   * @param v3Provider      V3Provider that issued the seized shares.
   * @param loanToken       Loan token to repay to Moolah.
   * @param seized          Number of V3 shares seized by Moolah.
   * @param redeemShares    If true, redeem V3 shares in callback; else hold as ERC-20.
   * @param minToken0Amt    Slippage guard passed to V3Provider.redeemShares.
   * @param minToken1Amt    Slippage guard passed to V3Provider.redeemShares.
   * @param swapToken0      Swap TOKEN0 → loanToken after redemption.
   * @param swapToken1      Swap TOKEN1 / native BNB → loanToken after redemption.
   * @param token0Pair      DEX router / pair for TOKEN0 swap.
   * @param token0Spender   Token0 approval target (set to token0Pair if same).
   * @param token1Pair      DEX router / pair for TOKEN1 / BNB swap.
   * @param token1Spender   Token1 approval target (set to token1Pair if same).
   * @param swapToken0Data  Calldata for TOKEN0 swap (e.g. from 1inch aggregator).
   * @param swapToken1Data  Calldata for TOKEN1 / BNB swap.
   */
  struct V3LiquidateData {
    address v3Provider;
    address loanToken;
    uint256 seized;
    bool redeemShares;
    uint256 minToken0Amt;
    uint256 minToken1Amt;
    bool swapToken0;
    bool swapToken1;
    address token0Pair;
    address token0Spender;
    address token1Pair;
    address token1Spender;
    bytes swapToken0Data;
    bytes swapToken1Data;
  }

  /* ──────────────────── flashLiquidate params ─────────────────────── */

  /**
   * @dev Parameters for flashLiquidate, bundled into a struct to avoid stack-too-deep.
   * @param v3Provider      Whitelisted V3Provider contract.
   * @param minToken0Amt    Min TOKEN0 from redeemShares.
   * @param minToken1Amt    Min TOKEN1 from redeemShares.
   * @param redeemShares    Redeem V3 shares in callback? If false, contract holds shares.
   * @param token0Pair      DEX pair for TOKEN0 → loanToken swap. address(0) = no swap.
   * @param token0Spender   Approval target for TOKEN0; if address(0), uses token0Pair.
   * @param token1Pair      DEX pair for TOKEN1 / BNB → loanToken swap. address(0) = no swap.
   * @param token1Spender   Approval target for TOKEN1; if address(0), uses token1Pair.
   * @param swapToken0Data  Aggregator calldata for TOKEN0 swap.
   * @param swapToken1Data  Aggregator calldata for TOKEN1 / BNB swap.
   */
  struct FlashLiquidateParams {
    address v3Provider;
    uint256 minToken0Amt;
    uint256 minToken1Amt;
    bool redeemShares;
    address token0Pair;
    address token0Spender;
    address token1Pair;
    address token1Spender;
    bytes swapToken0Data;
    bytes swapToken1Data;
  }

  /* ────────────────────── constructor / init ──────────────────────── */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address moolah) {
    require(moolah != address(0), "zero address");
    MOOLAH = moolah;
    _disableInitializers();
  }

  function initialize(address admin, address manager, address bot) external initializer {
    require(admin != address(0) && manager != address(0) && bot != address(0), "zero address");
    __AccessControl_init();
    __ReentrancyGuard_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
  }

  receive() external payable {}

  /* ─────────────────────── withdrawals ────────────────────────────── */

  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    token.safeTransfer(msg.sender, amount);
  }

  function withdrawETH(uint256 amount) external onlyRole(MANAGER) {
    msg.sender.safeTransferETH(amount);
  }

  /* ─────────────────────── whitelists ─────────────────────────────── */

  function setTokenWhitelist(address token, bool status) external onlyRole(MANAGER) {
    require(tokenWhitelist[token] != status, WhitelistSameStatus());
    tokenWhitelist[token] = status;
    emit TokenWhitelistChanged(token, status);
  }

  function setMarketWhitelist(bytes32 id, bool status) external onlyRole(MANAGER) {
    _setMarketWhitelist(id, status);
  }

  function batchSetMarketWhitelist(bytes32[] calldata ids, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < ids.length; i++) {
      _setMarketWhitelist(ids[i], status);
    }
  }

  function setPairWhitelist(address pair, bool status) external onlyRole(MANAGER) {
    require(pair != address(0), "zero address");
    require(pairWhitelist[pair] != status, WhitelistSameStatus());
    pairWhitelist[pair] = status;
    emit PairWhitelistChanged(pair, status);
  }

  function setV3ProviderWhitelist(address provider, bool status) external onlyRole(MANAGER) {
    require(provider != address(0), "zero address");
    require(v3Providers[provider] != status, WhitelistSameStatus());
    v3Providers[provider] = status;
    emit V3ProviderWhitelistChanged(provider, status);
  }

  function batchSetV3Providers(address[] calldata providers, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < providers.length; i++) {
      require(providers[i] != address(0), "zero address");
      v3Providers[providers[i]] = status;
      emit V3ProviderWhitelistChanged(providers[i], status);
    }
  }

  function _setMarketWhitelist(bytes32 id, bool status) internal {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(marketWhitelist[id] != status, WhitelistSameStatus());
    marketWhitelist[id] = status;
    emit MarketWhitelistChanged(id, status);
  }

  /* ───────────────────── core liquidation ─────────────────────────── */

  /**
   * @notice Basic liquidation. This contract must hold enough loanToken to cover repayment.
   *         Seized V3 shares are held by this contract; bot may later call redeemV3Shares.
   * @param id           Market id.
   * @param borrower     Position to liquidate.
   * @param seizedAssets Collateral shares to seize (pass 0 to use repaidShares instead).
   * @param repaidShares Debt shares to repay (pass 0 to use seizedAssets instead).
   */
  function liquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares
  ) external nonReentrant onlyRole(BOT) {
    require(marketWhitelist[id], NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);

    // Pre-approve Moolah to pull the repayment; cleared after the call.
    params.loanToken.safeApprove(MOOLAH, type(uint256).max);
    IMoolah(MOOLAH).liquidate(params, borrower, seizedAssets, repaidShares, "");
    params.loanToken.safeApprove(MOOLAH, 0);
  }

  /**
   * @notice Flash liquidation: Moolah delivers seized V3 shares to this contract inside
   *         the onMoolahLiquidate callback.  The callback optionally:
   *           1. Redeems V3 shares → TOKEN0 + TOKEN1 (TOKEN1 arrives as native BNB if WBNB).
   *           2. Swaps TOKEN0 → loanToken.
   *           3. Swaps TOKEN1 / BNB → loanToken.
   *           4. Approves loanToken to Moolah to satisfy repayment.
   *
   *         If `params.redeemShares == false`, shares are held as ERC-20 and the contract
   *         must already hold enough loanToken to cover repayment.
   * @param id           Market id.
   * @param borrower     Position to liquidate.
   * @param seizedAssets Collateral shares to seize (exactlyOneZero with repaidShares).
   * @param params       Flash liquidation parameters (see FlashLiquidateParams).
   */
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    FlashLiquidateParams calldata params
  ) external nonReentrant onlyRole(BOT) {
    require(marketWhitelist[id], NotWhitelisted());
    require(v3Providers[params.v3Provider], NotWhitelisted());
    _requirePairWhitelisted(params.token0Pair, params.token0Spender);
    _requirePairWhitelisted(params.token1Pair, params.token1Spender);

    IMoolah.MarketParams memory mp = IMoolah(MOOLAH).idToMarketParams(id);
    require(mp.collateralToken == params.v3Provider, "provider/market mismatch");

    address effectiveToken0Spender = params.token0Spender == address(0) ? params.token0Pair : params.token0Spender;
    address effectiveToken1Spender = params.token1Spender == address(0) ? params.token1Pair : params.token1Spender;

    (uint256 _seized, uint256 _repaid) = IMoolah(MOOLAH).liquidate(
      mp,
      borrower,
      seizedAssets,
      0,
      abi.encode(
        V3LiquidateData({
          v3Provider: params.v3Provider,
          loanToken: mp.loanToken,
          seized: seizedAssets,
          redeemShares: params.redeemShares,
          minToken0Amt: params.minToken0Amt,
          minToken1Amt: params.minToken1Amt,
          swapToken0: params.token0Pair != address(0) && params.swapToken0Data.length > 0,
          swapToken1: params.token1Pair != address(0) && params.swapToken1Data.length > 0,
          token0Pair: params.token0Pair,
          token0Spender: effectiveToken0Spender,
          token1Pair: params.token1Pair,
          token1Spender: effectiveToken1Spender,
          swapToken0Data: params.swapToken0Data,
          swapToken1Data: params.swapToken1Data
        })
      )
    );

    emit V3Liquidation(id, params.v3Provider, borrower, _seized, _repaid, 0, 0);
  }

  /**
   * @notice Redeem V3 shares held by this contract.
   *         TOKEN1 arrives as native BNB if the V3Provider pool contains WBNB.
   * @param v3Provider V3Provider whose shares to redeem.
   * @param shares     Number of shares to redeem.
   * @param minAmt0    Min TOKEN0 to receive (slippage guard).
   * @param minAmt1    Min TOKEN1 / BNB to receive (slippage guard).
   * @param receiver   Recipient of TOKEN0 and TOKEN1 / BNB.
   */
  function redeemV3Shares(
    address v3Provider,
    uint256 shares,
    uint256 minAmt0,
    uint256 minAmt1,
    address receiver
  ) external nonReentrant onlyRole(BOT) returns (uint256 amount0, uint256 amount1) {
    require(v3Providers[v3Provider], NotWhitelisted());
    (amount0, amount1) = IV3Provider(v3Provider).redeemShares(shares, minAmt0, minAmt1, receiver);
  }

  /* ─────────────────────── sell tokens ────────────────────────────── */

  /// @notice Sell an ERC-20 token (pair == spender).
  function sellToken(
    address pair,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external nonReentrant onlyRole(BOT) {
    _sellToken(pair, pair, tokenIn, tokenOut, amountIn, amountOutMin, swapData);
  }

  /// @notice Sell an ERC-20 token with separate pair and spender (e.g. DEX aggregator).
  function sellToken(
    address pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external nonReentrant onlyRole(BOT) {
    require(pair != spender, "pair and spender cannot be same address");
    require(pairWhitelist[spender], NotWhitelisted());
    _sellToken(pair, spender, tokenIn, tokenOut, amountIn, amountOutMin, swapData);
  }

  /// @notice Sell native BNB held by this contract.
  function sellBNB(
    address pair,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external nonReentrant onlyRole(BOT) {
    require(tokenWhitelist[BNB_ADDRESS], NotWhitelisted());
    require(tokenWhitelist[tokenOut], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(amountIn > 0, "amountIn zero");
    require(address(this).balance >= amountIn, ExceedAmount());

    uint256 beforeIn = address(this).balance;
    uint256 beforeOut = tokenOut.balanceOf(address(this));

    (bool success, ) = pair.call{ value: amountIn }(swapData);
    require(success, SwapFailed());

    uint256 actualIn = beforeIn - address(this).balance;
    uint256 actualOut = tokenOut.balanceOf(address(this)) - beforeOut;

    require(actualIn <= amountIn, ExceedAmount());
    require(actualOut >= amountOutMin, NoProfit());

    emit SellToken(pair, pair, BNB_ADDRESS, tokenOut, amountIn, actualOut);
  }

  /* ──────────────────── Moolah callback ───────────────────────────── */

  /**
   * @dev Called by Moolah immediately before it pulls repaidAssets of loanToken from
   *      this contract.  At this point Moolah has already transferred the seized V3
   *      shares to address(this).
   */
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH, OnlyMoolah());
    V3LiquidateData memory d = abi.decode(data, (V3LiquidateData));

    if (d.redeemShares) {
      address token0 = IV3Provider(d.v3Provider).TOKEN0();
      address token1 = IV3Provider(d.v3Provider).TOKEN1();

      // Redeem V3 shares → TOKEN0 as ERC-20, TOKEN1 as ERC-20 or native BNB (if WBNB).
      (uint256 amount0, uint256 amount1) = IV3Provider(d.v3Provider).redeemShares(
        d.seized,
        d.minToken0Amt,
        d.minToken1Amt,
        address(this)
      );

      // Swap TOKEN0 → loanToken (skip if already loanToken or no swap requested).
      if (d.swapToken0 && amount0 > 0 && token0 != d.loanToken) {
        token0.safeApprove(d.token0Spender, amount0);
        (bool ok, ) = d.token0Pair.call(d.swapToken0Data);
        require(ok, SwapFailed());
        token0.safeApprove(d.token0Spender, 0);
      }

      // Swap TOKEN1 / native BNB → loanToken.
      // V3Provider always unwraps WBNB to native BNB, so use call{value} for WBNB pools.
      if (d.swapToken1 && amount1 > 0 && token1 != d.loanToken) {
        if (token1 == WBNB) {
          (bool ok, ) = d.token1Pair.call{ value: amount1 }(d.swapToken1Data);
          require(ok, SwapFailed());
        } else {
          token1.safeApprove(d.token1Spender, amount1);
          (bool ok, ) = d.token1Pair.call(d.swapToken1Data);
          require(ok, SwapFailed());
          token1.safeApprove(d.token1Spender, 0);
        }
      }

      if (d.loanToken.balanceOf(address(this)) < repaidAssets) revert NoProfit();
    }

    // Approve Moolah to pull the repayment (always done, flash or pre-funded).
    d.loanToken.safeApprove(MOOLAH, repaidAssets);
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  function _sellToken(
    address pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) private {
    require(tokenWhitelist[tokenIn], NotWhitelisted());
    require(tokenWhitelist[tokenOut], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(amountIn > 0, "amountIn zero");
    require(tokenIn.balanceOf(address(this)) >= amountIn, ExceedAmount());

    uint256 beforeIn = tokenIn.balanceOf(address(this));
    uint256 beforeOut = tokenOut.balanceOf(address(this));

    tokenIn.safeApprove(spender, amountIn);
    (bool success, ) = pair.call(swapData);
    require(success, SwapFailed());

    uint256 actualIn = beforeIn - tokenIn.balanceOf(address(this));
    uint256 actualOut = tokenOut.balanceOf(address(this)) - beforeOut;

    require(actualIn <= amountIn, ExceedAmount());
    require(actualOut >= amountOutMin, NoProfit());

    tokenIn.safeApprove(spender, 0);

    emit SellToken(pair, spender, tokenIn, tokenOut, actualIn, actualOut);
  }

  /// @dev Validates that both pair and spender (when non-zero) are in the pair whitelist.
  function _requirePairWhitelisted(address pair, address spender) internal view {
    if (pair == address(0)) return;
    require(pairWhitelist[pair], NotWhitelisted());
    if (spender != address(0) && spender != pair) require(pairWhitelist[spender], NotWhitelisted());
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

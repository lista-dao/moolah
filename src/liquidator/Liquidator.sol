// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./ILiquidator.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ISmartProvider } from "../provider/interfaces/IProvider.sol";
import { ILiquidationVault } from "./ILiquidationVault.sol";

contract Liquidator is ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, ILiquidator {
  using MarketParamsLib for IMoolah.MarketParams;
  using SafeTransferLib for address;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyMoolah();
  error ExceedAmount();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();
  error NotAuthorized();
  error InvalidFundSource();

  address public immutable MOOLAH;
  mapping(address => bool) public tokenWhitelist;
  mapping(bytes32 => bool) public marketWhitelist;
  mapping(address => bool) public pairWhitelist;
  mapping(address => bool) public smartProviders;
  /// @dev Shared liquidation fund pool (LiquidationVault). 0 => legacy behavior (no pull/reflow).
  ///      Storage appended for the UUPS upgrade; no existing slot is moved.
  address public fundSource;
  /// @dev Tokens excluded from reflow to the vault (smart-collateral LP tokens the vault cannot sell).
  ///      Guards against a wrong-entry plain liquidate seizing LP and pushing it into the vault; the LP
  ///      stays here as a process holding to be redeemed via redeemSmartCollateral. Storage appended.
  mapping(address => bool) public reflowBlacklist;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // manager role
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  event TokenWhitelistChanged(address indexed token, bool added);
  event MarketWhitelistChanged(bytes32 id, bool added);
  event PairWhitelistChanged(address pair, bool added);
  event SmartProvidersChanged(address provider, bool added);
  event FundSourceChanged(address indexed oldFundSource, address indexed newFundSource);
  event FundReflowed(address indexed token, uint256 amount);
  event ReflowBlacklistChanged(address indexed token, bool blacklisted);
  event SellToken(
    address pair,
    address spender,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 actualAmountOut
  );
  event SmartLiquidation(
    bytes32 indexed id,
    address indexed lpToken,
    address indexed collateralToken,
    uint256 lpAmount,
    uint256 minToken0Amt,
    uint256 minToken1Amt,
    uint256 amount0,
    uint256 amount1
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    require(moolah != address(0), ZERO_ADDRESS);
    _disableInitializers();
    MOOLAH = moolah;
  }

  /// @dev initializes the contract.
  /// @param admin The address of the admin.
  /// @param manager The address of the manager.
  /// @param bot The address of the bot.
  function initialize(address admin, address manager, address bot) public initializer {
    require(admin != address(0), ZERO_ADDRESS);
    require(manager != address(0), ZERO_ADDRESS);
    require(bot != address(0), ZERO_ADDRESS);
    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
    _setRoleAdmin(BOT, MANAGER);
  }

  /// @dev Post-upgrade step for the live proxy: make MANAGER the admin of the BOT role so BOT hot-key
  ///      rotation is a MANAGER (multisig) action rather than a DEFAULT_ADMIN one. New deployments
  ///      already set this in initialize; call this via upgradeToAndCall for existing ones.
  function setBotRoleAdmin() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setRoleAdmin(BOT, MANAGER);
  }

  receive() external payable {}

  /// @dev withdraws ERC20 tokens. Gate relaxed for the shared fund pool: MANAGER or fundSource
  ///      (the vault's collectERC20 call). Transfer target stays msg.sender, so the vault collects.
  /// @param token The address of the token.
  /// @param amount The amount to withdraw.
  function withdrawERC20(address token, uint256 amount) external {
    require(hasRole(MANAGER, msg.sender) || msg.sender == fundSource, NotAuthorized());
    token.safeTransfer(msg.sender, amount);
  }
  /// @dev withdraws ETH. Gate relaxed as withdrawERC20.
  /// @param amount The amount to withdraw.
  function withdrawETH(uint256 amount) external {
    require(hasRole(MANAGER, msg.sender) || msg.sender == fundSource, NotAuthorized());
    msg.sender.safeTransferETH(amount);
  }

  /// @dev Sets the shared liquidation fund pool. Allows 0 (grey-scale rollback to legacy
  ///      behavior). A non-zero fundSource gains withdraw* pull rights, so it must be a contract that
  ///      has already registered this liquidator (guards against a mis-set address draining assets).
  /// @param _fundSource The address of the LiquidationVault, or 0 to disable.
  function setFundSource(address _fundSource) external onlyRole(MANAGER) {
    if (_fundSource != address(0)) {
      require(
        _fundSource.code.length > 0 && ILiquidationVault(_fundSource).liquidators(address(this)),
        InvalidFundSource()
      );
    }
    emit FundSourceChanged(fundSource, _fundSource);
    fundSource = _fundSource;
  }

  /// @dev Adds/removes a token from the reflow blacklist. Blacklisted tokens (smart-collateral LP) are
  ///      never pushed to the vault; they remain here to be redeemed via redeemSmartCollateral.
  function setReflowBlacklist(address token, bool status) external onlyRole(MANAGER) {
    require(token != address(0), ZERO_ADDRESS);
    reflowBlacklist[token] = status;
    emit ReflowBlacklistChanged(token, status);
  }

  /// @dev sets the token whitelist.
  /// @param token The address of the token.
  /// @param status The status of the token.
  function setTokenWhitelist(address token, bool status) external onlyRole(MANAGER) {
    require(tokenWhitelist[token] != status, WhitelistSameStatus());
    tokenWhitelist[token] = status;
    emit TokenWhitelistChanged(token, status);
  }

  /// @dev sets the market whitelist.
  /// @param id The id of the market.
  /// @param status The status of the market.
  function setMarketWhitelist(bytes32 id, bool status) external onlyRole(MANAGER) {
    _setMarketWhitelist(id, status);
  }

  /// @dev batch sets the market whitelist.
  /// @param ids The array of market ids.
  /// @param status The status to set for all markets.
  function batchSetMarketWhitelist(bytes32[] calldata ids, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < ids.length; i++) {
      bytes32 id = ids[i];
      _setMarketWhitelist(id, status);
    }
  }

  /// @dev sets the smart collateral providers.
  /// @param providers The array of smart collateral providers.
  /// @param status The status of the providers.
  function batchSetSmartProviders(address[] calldata providers, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < providers.length; i++) {
      address provider = providers[i];
      smartProviders[provider] = status;
      emit SmartProvidersChanged(provider, status);
    }
  }

  function _setMarketWhitelist(bytes32 id, bool status) internal {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(marketWhitelist[id] != status, WhitelistSameStatus());
    marketWhitelist[id] = status;
    emit MarketWhitelistChanged(id, status);
  }

  /// @dev sets the pair whitelist.
  /// @param pair The address of the pair.
  /// @param status The status of the pair.
  function setPairWhitelist(address pair, bool status) external onlyRole(MANAGER) {
    require(pair != address(0), ZERO_ADDRESS);
    require(pairWhitelist[pair] != status, WhitelistSameStatus());
    pairWhitelist[pair] = status;
    emit PairWhitelistChanged(pair, status);
  }

  /// @dev sell tokens.
  /// @param pair The address of the pair.
  /// @param tokenIn The address of the input token.
  /// @param tokenOut The address of the output token.
  /// @param amountIn The amount to sell.
  /// @param amountOutMin The minimum amount to receive.
  /// @param swapData The swap data passed to low level swap call. Should be obtained from aggregator API like 1inch.
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

  /// @dev sell tokens.
  /// @param pair The address of the pair.
  /// @param spender The address of the spender.
  /// @param tokenIn The address of the input token.
  /// @param tokenOut The address of the output token.
  /// @param amountIn The amount to sell.
  /// @param amountOutMin The minimum amount to receive.
  /// @param swapData The swap data passed to low level swap call. Should be obtained from aggregator API like 1inch.
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

    emit SellToken(pair, spender, tokenIn, tokenOut, actualAmountIn, actualAmountOut);
  }

  /// @dev sell BNB.
  /// @param pair The address of the pair.
  /// @param tokenOut The address of the output token.
  /// @param amountIn The BNB amount to sell.
  /// @param amountOutMin The minimum amount to receive.
  /// @param swapData The swap data passed to low level swap call. Should be obtained from aggregator API like 1inch.
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

    uint256 beforeTokenIn = address(this).balance;
    uint256 beforeTokenOut = tokenOut.balanceOf(address(this));

    (bool success, ) = pair.call{ value: amountIn }(swapData);
    require(success, SwapFailed());

    uint256 actualAmountIn = beforeTokenIn - address(this).balance;
    uint256 actualAmountOut = tokenOut.balanceOf(address(this)) - beforeTokenOut;

    require(actualAmountIn <= amountIn, ExceedAmount());
    require(actualAmountOut >= amountOutMin, NoProfit());

    emit SellToken(pair, pair, BNB_ADDRESS, tokenOut, amountIn, actualAmountOut);
  }

  /// @dev flash liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  /// @param swapCollateralData The swap data passed to low level swap call for collateral swapping to loan token. Should be obtained from aggregator API like 1inch with slippage considered.
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapCollateralData
  ) external nonReentrant onlyRole(BOT) {
    _flashLiquidate(id, borrower, seizedAssets, pair, pair, swapCollateralData);
  }

  /// @dev flash liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  /// @param spender The address of the spender.
  /// @param swapCollateralData The swap data passed to low level swap call for collateral swapping to loan token. Should be obtained from aggregator API like 1inch with slippage considered.
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    address spender,
    bytes calldata swapCollateralData
  ) external nonReentrant onlyRole(BOT) {
    _flashLiquidate(id, borrower, seizedAssets, pair, spender, swapCollateralData);
  }

  function _flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    address spender,
    bytes calldata swapCollateralData
  ) private {
    require(marketWhitelist[id], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(pairWhitelist[spender], NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(
        MoolahLiquidateData(
          params.collateralToken,
          params.loanToken,
          seizedAssets,
          pair,
          spender,
          swapCollateralData,
          true,
          false,
          address(0),
          0,
          0,
          address(0),
          address(0),
          "",
          ""
        )
      )
    );
    // reflow the arbitrage profit residue to the vault (no-op when fundSource == 0).
    _reflow(params.loanToken);
    _reflow(params.collateralToken);
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param repaidShares The amount of shares to repay.
  function liquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares
  ) external nonReentrant onlyRole(BOT) {
    require(marketWhitelist[id], NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(
        MoolahLiquidateData(
          params.collateralToken,
          params.loanToken,
          seizedAssets,
          address(0),
          address(0),
          "",
          false,
          false,
          address(0),
          0,
          0,
          address(0),
          address(0),
          "",
          ""
        )
      )
    );
    // reflow leftover balances to the vault (no-op when fundSource == 0).
    _reflow(params.loanToken);
    _reflow(params.collateralToken);
  }

  /// @dev liquidates a position with smart collateral.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param smartProvider The address of the smart collateral provider.
  /// @param seizedAssets The amount of assets to seize.
  /// @param repaidShares The amount of shares to repay.
  /// @param payload The payload for the liquidation (min amounts for SmartProvider liquidation).
  /// @return The actual seized assets and repaid assets.
  function liquidateSmartCollateral(
    bytes32 id,
    address borrower,
    address smartProvider,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes memory payload
  ) external nonReentrant onlyRole(BOT) returns (uint256, uint256) {
    require(smartProviders[smartProvider], NotWhitelisted());
    address lpToken = ISmartProvider(smartProvider).dexLP();
    require(marketWhitelist[id], NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    require(ISmartProvider(smartProvider).TOKEN() == params.collateralToken, "Invalid smart provider");

    uint256 collBalanceBefore = IERC20(params.collateralToken).balanceOf(address(this));
    (uint256 minAmount0, uint256 minAmount1) = abi.decode(payload, (uint256, uint256));
    (uint256 _seizedAssets, uint256 _repaidAssets) = IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(
        MoolahLiquidateData(
          params.collateralToken,
          params.loanToken,
          seizedAssets,
          address(0),
          address(0),
          "",
          false,
          false,
          smartProvider, // not used since `swapSmartCollateral` flag is false
          minAmount0, // not used
          minAmount1, // not used
          address(0),
          address(0),
          "",
          ""
        )
      )
    );
    uint256 collAmount = IERC20(params.collateralToken).balanceOf(address(this)) - collBalanceBefore;
    require(collAmount > 0, "No collateral seized");

    (uint256 amount0, uint256 amount1) = ISmartProvider(smartProvider).redeemLpCollateral(
      collAmount,
      minAmount0,
      minAmount1
    );

    emit SmartLiquidation(id, lpToken, params.collateralToken, collAmount, minAmount0, minAmount1, amount0, amount1);
    // this entry redeemed token0/token1 in the same tx — reflow them plus any loanToken.
    _reflow(params.loanToken);
    _reflow(ISmartProvider(smartProvider).token(0));
    _reflow(ISmartProvider(smartProvider).token(1));
    return (_seizedAssets, _repaidAssets);
  }

  /// @dev flash liquidates a position with smart collateral.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param smartProvider The address of the smart collateral provider.
  /// @param seizedAssets The amount of assets to seize.
  /// @param token0Pair The address of the token0 pair.
  /// @param token1Pair The address of the token1 pair.
  /// @param swapToken0Data The swap data passed to low level swap call for token0 swapping to loan token. Should be obtained from aggregator API like 1inch with slippage considered.
  /// @param swapToken1Data The swap data passed to low level swap call for token1 swapping to loan token. Should be obtained from aggregator API like 1inch with slippage considered.
  /// @param payload The payload for the liquidation (min amounts for SmartProvider liquidation).
  /// @return The actual seized assets and repaid assets.
  function flashLiquidateSmartCollateral(
    bytes32 id,
    address borrower,
    address smartProvider,
    uint256 seizedAssets,
    address token0Pair,
    address token1Pair,
    bytes calldata swapToken0Data,
    bytes calldata swapToken1Data,
    bytes memory payload
  ) external nonReentrant onlyRole(BOT) returns (uint256, uint256) {
    require(smartProviders[smartProvider], NotWhitelisted());
    require(marketWhitelist[id], NotWhitelisted());
    require(pairWhitelist[token0Pair], NotWhitelisted());
    require(pairWhitelist[token1Pair], NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    require(ISmartProvider(smartProvider).TOKEN() == params.collateralToken, "Invalid smart provider");
    (uint256 minAmount0, uint256 minAmount1) = abi.decode(payload, (uint256, uint256));

    MoolahLiquidateData memory callback = MoolahLiquidateData(
      params.collateralToken,
      params.loanToken,
      seizedAssets,
      address(0),
      address(0),
      "",
      false,
      true,
      smartProvider,
      minAmount0,
      minAmount1,
      token0Pair,
      token1Pair,
      swapToken0Data,
      swapToken1Data
    );

    (uint256 _seizedAssets, uint256 _repaidAssets) = IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(callback)
    );
    // reflow token0/token1/loanToken to the vault (native leg handled by _reflow).
    _reflow(params.loanToken);
    _reflow(ISmartProvider(smartProvider).token(0));
    _reflow(ISmartProvider(smartProvider).token(1));
    return (_seizedAssets, _repaidAssets);
  }

  /// @dev redeems smart collateral LP tokens.
  /// @param smartProvider The address of the smart collateral provider.
  /// @param lpAmount The amount of LP collateral tokens to redeem.
  /// @param minToken0Amt The minimum amount of token0 to receive.
  /// @param minToken1Amt The minimum amount of token1 to receive.
  /// @return The amount of token0 and token1 redeemed.
  function redeemSmartCollateral(
    address smartProvider,
    uint256 lpAmount,
    uint256 minToken0Amt,
    uint256 minToken1Amt
  ) external nonReentrant onlyRole(BOT) returns (uint256, uint256) {
    require(smartProviders[smartProvider], NotWhitelisted());
    (uint256 amount0, uint256 amount1) = ISmartProvider(smartProvider).redeemLpCollateral(
      lpAmount,
      minToken0Amt,
      minToken1Amt
    );
    // reflow redeemed token0/token1 to the vault (native leg handled by _reflow).
    _reflow(ISmartProvider(smartProvider).token(0));
    _reflow(ISmartProvider(smartProvider).token(1));
    return (amount0, amount1);
  }

  /// @dev the function will be called by the Moolah contract when liquidate.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data.
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH, OnlyMoolah());
    MoolahLiquidateData memory arb = abi.decode(data, (MoolahLiquidateData));
    if (arb.swapCollateral) {
      require(!arb.swapSmartCollateral, "only swap collateral or smart collateral");
      uint256 before = arb.loanToken.balanceOf(address(this));

      arb.collateralToken.safeApprove(arb.collateralRouterSpender, arb.seized);
      (bool success, ) = arb.collateralPair.call(arb.swapCollateralData);
      require(success, SwapFailed());

      uint256 out = arb.loanToken.balanceOf(address(this)) - before;

      if (out < repaidAssets) revert NoProfit();

      arb.collateralToken.safeApprove(arb.collateralRouterSpender, 0);
    } else if (arb.swapSmartCollateral) {
      uint256 before = arb.loanToken.balanceOf(address(this));
      // redeem lp
      (uint256 amount0, uint256 amount1) = ISmartProvider(arb.smartProvider).redeemLpCollateral(
        arb.seized,
        arb.minToken0Amt,
        arb.minToken1Amt
      );

      address token0 = ISmartProvider(arb.smartProvider).token(0);
      address token1 = ISmartProvider(arb.smartProvider).token(1);

      // swap token0 and token1 to loanToken if needed
      if (amount0 > 0 && token0 != arb.loanToken) {
        if (token0 != BNB_ADDRESS) token0.safeApprove(arb.token0Pair, amount0);
        uint256 _value = token0 == BNB_ADDRESS ? arb.minToken0Amt : 0;
        (bool success, ) = arb.token0Pair.call{ value: _value }(arb.swapToken0Data);
        require(success, SwapFailed());
      }

      if (amount1 > 0 && token1 != arb.loanToken) {
        if (token1 != BNB_ADDRESS) token1.safeApprove(arb.token1Pair, amount1);
        uint256 _value = token1 == BNB_ADDRESS ? arb.minToken1Amt : 0;
        (bool success, ) = arb.token1Pair.call{ value: _value }(arb.swapToken1Data);
        require(success, SwapFailed());
      }
      uint256 out = arb.loanToken.balanceOf(address(this)) - before;

      if (out < repaidAssets) revert NoProfit();
      if (token0 != BNB_ADDRESS) token0.safeApprove(arb.token0Pair, 0);
      if (token1 != BNB_ADDRESS) token1.safeApprove(arb.token1Pair, 0);
    } else if (fundSource != address(0)) {
      // normal pre-funded path (no self-funded swap). Pull the exact shortfall from the vault.
      // repaidAssets is already exact here (Moolah computed it before this callback, before its
      // transferFrom). Local balance is consumed first, so the vault only tops up the difference.
      uint256 bal = arb.loanToken.balanceOf(address(this));
      if (bal < repaidAssets) {
        ILiquidationVault(fundSource).provideFund(arb.loanToken, repaidAssets - bal);
      }
    }

    arb.loanToken.safeApprove(MOOLAH, repaidAssets);
  }

  /// @dev Reflow (push) the full balance of `token` to the vault. No-op when fundSource is unset or
  ///      the balance is zero. `token == BNB_ADDRESS` reflows native BNB via safeTransferETH.
  function _reflow(address token) private {
    address _fundSource = fundSource;
    if (_fundSource == address(0)) return;
    // Never push blacklisted tokens (smart-collateral LP) to the vault — it cannot sell them. They
    // stay here as a process holding, recoverable via redeemSmartCollateral.
    if (reflowBlacklist[token]) return;
    if (token == BNB_ADDRESS) {
      uint256 bal = address(this).balance;
      if (bal > 0) {
        _fundSource.safeTransferETH(bal);
        emit FundReflowed(token, bal);
      }
    } else {
      uint256 bal = token.balanceOf(address(this));
      if (bal > 0) {
        token.safeTransfer(_fundSource, bal);
        emit FundReflowed(token, bal);
      }
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

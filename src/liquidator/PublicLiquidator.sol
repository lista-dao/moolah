// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "./IPublicLiquidator.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import "moolah/libraries/ConstantsLib.sol";
import { ISmartProvider } from "../provider/interfaces/IProvider.sol";

contract PublicLiquidator is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IPublicLiquidator {
  using MarketParamsLib for IMoolah.MarketParams;
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using SafeTransferLib for address;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyMoolah();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();
  error EitherOneZero();

  address public immutable MOOLAH;
  mapping(bytes32 => bool) public marketWhitelist;
  mapping(bytes32 => mapping(address => bool)) public marketUserWhitelist;
  mapping(address => bool) public pairWhitelist;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  event MarketWhitelistChanged(bytes32 id, bool added);
  event MarketUserWhitelistChanged(bytes32 id, address user, bool added);
  event PairWhitelistChanged(address pair, bool added);
  event Liquidated(
    bytes32 indexed id,
    address indexed borrower,
    uint256 seizedAssets,
    uint256 repaidAssets,
    uint256 repaidShares,
    address liquidator
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
  }

  /// @dev sets the market whitelist.
  /// @param id The id of the market.
  /// @param status The status of the market.
  function setMarketWhitelist(bytes32 id, bool status) external onlyRole(BOT) {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(!IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)), "market is already open for liquidate");
    require(marketWhitelist[id] != status, WhitelistSameStatus());
    marketWhitelist[id] = status;
    emit MarketWhitelistChanged(id, status);
  }

  /// @dev sets the market user whitelist.
  /// @param id The id of the market.
  /// @param user The address of the user.
  /// @param status The status of the user.
  function setMarketUserWhitelist(bytes32 id, address user, bool status) external onlyRole(BOT) {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(
      !marketWhitelist[id] && !IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)),
      "market is already open for liquidate"
    );
    require(marketUserWhitelist[id][user] != status, WhitelistSameStatus());
    marketUserWhitelist[id][user] = status;
    emit MarketUserWhitelistChanged(id, user, status);
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

  /// @dev flash liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  /// @param swapCollateralData The swap data.
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapCollateralData
  ) external nonReentrant {
    require(pairWhitelist[pair], NotWhitelisted());
    require(isLiquidatable(id, borrower), NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    // accrue interest for the market before calculate how much loan token is needed
    IMoolah(MOOLAH).accrueInterest(params);
    // calculate how much loan token to repay
    uint256 repayAmount = loanTokenAmountNeed(id, seizedAssets, 0);
    // pre-balance of loan token
    uint256 loanTokenBalanceBefore = params.loanToken.balanceOf(address(this));
    // liquidate borrower's position
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
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = params.loanToken.balanceOf(address(this));
    // check if the liquidator made a profit
    if (loanTokenBalanceAfter <= loanTokenBalanceBefore) revert NoProfit();
    // transfer profit to the liquidator
    params.loanToken.safeTransfer(msg.sender, loanTokenBalanceAfter - loanTokenBalanceBefore);
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, repayAmount, 0, msg.sender);
  }

  /// @dev flash liquidates a position with smart collateral.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param smartProvider The address of the smart collateral provider.
  /// @param seizedAssets The amount of assets to seize.
  /// @param token0Pair The address of the token0 pair.
  /// @param token1Pair The address of the token1 pair.
  /// @param swapToken0Data The swap data for token0.
  /// @param swapToken1Data The swap data for token1.
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
  ) external nonReentrant returns (uint256, uint256) {
    require(pairWhitelist[token0Pair], NotWhitelisted());
    require(pairWhitelist[token1Pair], NotWhitelisted());
    require(isLiquidatable(id, borrower), NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    require(ISmartProvider(smartProvider).TOKEN() == params.collateralToken, "Invalid smart provider");
    (uint256 minAmount0, uint256 minAmount1) = abi.decode(payload, (uint256, uint256));
    // accrue interest for the market before calculate how much loan token is needed
    IMoolah(MOOLAH).accrueInterest(params);
    // calculate how much loan token to repay
    uint256 repayAmount = loanTokenAmountNeed(id, seizedAssets, 0);
    // pre-balance of loan token
    uint256 loanTokenAmount = params.loanToken.balanceOf(address(this));
    // pre-balance of token0 and token1
    (uint256 token0Bal, uint256 token1Bal) = _liquidityBalances(smartProvider);
    // liquidate borrower's position
    MoolahLiquidateData memory callback = MoolahLiquidateData(
      params.collateralToken,
      params.loanToken,
      seizedAssets,
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
    (uint256 _seizedAssets, ) = IMoolah(MOOLAH).liquidate(params, borrower, seizedAssets, 0, abi.encode(callback));
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = params.loanToken.balanceOf(address(this));
    // check if the liquidator made a profit
    if (loanTokenBalanceAfter <= loanTokenAmount) revert NoProfit();
    // transfer profit to the liquidator
    params.loanToken.safeTransfer(msg.sender, loanTokenBalanceAfter - loanTokenAmount);

    // return excess token0 and token1 to msg.sender if any
    _sendExcessLiquidityTokens(smartProvider, token0Bal, token1Bal, msg.sender);
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, repayAmount, 0, msg.sender);
    return (_seizedAssets, repayAmount);
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external nonReentrant {
    require(isLiquidatable(id, borrower), NotWhitelisted());
    require(seizedAssets == 0 || repaidShares == 0, EitherOneZero());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);

    // accrue interest for the market before calculate how much loan token is needed
    IMoolah(MOOLAH).accrueInterest(params);
    // calculate how much loan token to transfer
    uint256 loanTokenAmount = loanTokenAmountNeed(id, seizedAssets, repaidShares);
    // pre-balance of loan token
    uint256 loanTokenBalanceBefore = params.loanToken.balanceOf(address(this));
    // transfer loan token to this contract
    params.loanToken.safeTransferFrom(msg.sender, address(this), loanTokenAmount);

    // pre-balance of collateral token
    uint256 collateralTokenBalanceBefore = params.collateralToken.balanceOf(address(this));
    // liquidate borrower's position
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
    // post-balance of collateral token
    uint256 collateralTokenBalanceAfter = params.collateralToken.balanceOf(address(this));
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = params.loanToken.balanceOf(address(this));
    // check if the liquidator made a profit
    if (collateralTokenBalanceAfter <= collateralTokenBalanceBefore) revert NoProfit();
    // transfer bid collateral to the liquidator
    params.collateralToken.safeTransfer(msg.sender, collateralTokenBalanceAfter - collateralTokenBalanceBefore);
    // transfer unused loan token back to the liquidator
    if (loanTokenBalanceAfter > loanTokenBalanceBefore) {
      params.loanToken.safeTransfer(msg.sender, loanTokenBalanceAfter - loanTokenBalanceBefore);
    }
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, loanTokenAmount, repaidShares, msg.sender);
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
  ) external nonReentrant returns (uint256, uint256) {
    require(isLiquidatable(id, borrower), NotWhitelisted());
    require(seizedAssets == 0 || repaidShares == 0, EitherOneZero());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    require(ISmartProvider(smartProvider).TOKEN() == params.collateralToken, "Invalid smart provider");

    // accrue interest for the market before calculate how much loan token is needed
    IMoolah(MOOLAH).accrueInterest(params);
    // calculate how much loan token to transfer
    uint256 loanTokenAmount = loanTokenAmountNeed(id, seizedAssets, repaidShares);
    // pre-balance of loan token
    uint256 loanTokenBalanceBefore = params.loanToken.balanceOf(address(this));
    // transfer loan token to this contract
    params.loanToken.safeTransferFrom(msg.sender, address(this), loanTokenAmount);

    // pre-balance of collateral token
    uint256 collateralTokenBalanceBefore = params.collateralToken.balanceOf(address(this));
    // liquidate borrower's position
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
    // post-balance of collateral token
    uint256 collateralTokenBalanceAfter = params.collateralToken.balanceOf(address(this));
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = params.loanToken.balanceOf(address(this));
    // check if the liquidator made a profit
    if (collateralTokenBalanceAfter <= collateralTokenBalanceBefore) revert NoProfit();

    // redeem lp collateral from smart collateral provider and transfer to msg.sender
    (uint256 token0Amount, uint256 token1Amount) = ISmartProvider(smartProvider).redeemLpCollateral(
      collateralTokenBalanceAfter - collateralTokenBalanceBefore,
      minAmount0,
      minAmount1
    );

    // transfer redeemed token0 to msg.sender
    if (token0Amount > 0) {
      address token0 = ISmartProvider(smartProvider).token(0);
      if (token0 == BNB_ADDRESS) {
        msg.sender.safeTransferETH(token0Amount);
      } else {
        token0.safeTransfer(msg.sender, token0Amount);
      }
    }
    // transfer redeemed token1 to msg.sender
    if (token1Amount > 0) {
      address token1 = ISmartProvider(smartProvider).token(1);
      if (token1 == BNB_ADDRESS) {
        msg.sender.safeTransferETH(token1Amount);
      } else {
        token1.safeTransfer(msg.sender, token1Amount);
      }
    }

    // transfer unused loan token back to the liquidator
    if (loanTokenBalanceAfter > loanTokenBalanceBefore) {
      params.loanToken.safeTransfer(msg.sender, loanTokenBalanceAfter - loanTokenBalanceBefore);
    }
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, loanTokenAmount, repaidShares, msg.sender);
    return (_seizedAssets, _repaidAssets);
  }

  /// @dev calculates the amount of loan token needed to repay the shares.
  ///      exactly the same logic as in the Moolah contract.
  /// @param id The id of the market.
  /// @param seizedAssets The amount of assets seized.
  /// @param repaidShares The amount of shares to repay.
  function loanTokenAmountNeed(bytes32 id, uint256 seizedAssets, uint256 repaidShares) public view returns (uint256) {
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah.Market memory market = IMoolah(MOOLAH).market(id);
    uint256 _repaidShares = repaidShares;
    // calculate by amt of collateral to buy
    if (seizedAssets > 0) {
      uint256 liquidationIncentiveFactor = UtilsLib.min(
        MAX_LIQUIDATION_INCENTIVE_FACTOR,
        WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - params.lltv))
      );
      uint256 collateralPrice = IMoolah(MOOLAH).getPrice(params);
      uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);
      _repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
        market.totalBorrowAssets,
        market.totalBorrowShares
      );
    }
    // calculate by loan token amt need to repay the shares
    return _repaidShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
  }

  /// @dev remove borrower from the whitelist after liquidation.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  function postLiquidate(IMoolah.MarketParams memory params, bytes32 id, address borrower) internal {
    // remove user from whitelist if position is healthy and inside whitelist
    if (IMoolah(MOOLAH).isHealthy(params, id, borrower) && marketUserWhitelist[id][borrower]) {
      marketUserWhitelist[id][borrower] = false;
      emit MarketUserWhitelistChanged(id, borrower, false);
    }
  }

  /// @dev checks if a position is able to liquidate.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  function isLiquidatable(bytes32 id, address borrower) internal view returns (bool) {
    return
      IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)) ||
      marketWhitelist[id] ||
      marketUserWhitelist[id][borrower];
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

      arb.collateralToken.safeApprove(arb.collateralPair, arb.seized);
      (bool success, ) = arb.collateralPair.call(arb.swapCollateralData);
      require(success, SwapFailed());

      uint256 out = arb.loanToken.balanceOf(address(this)) - before;

      if (out < repaidAssets) revert NoProfit();

      // revoke approval for the pair
      arb.collateralToken.safeApprove(arb.collateralPair, 0);
    } else if (arb.swapSmartCollateral) {
      // redeem lp
      (uint256 amount0, uint256 amount1) = ISmartProvider(arb.smartProvider).redeemLpCollateral(
        arb.seized,
        arb.minToken0Amt,
        arb.minToken1Amt
      );

      address token0 = ISmartProvider(arb.smartProvider).token(0);
      address token1 = ISmartProvider(arb.smartProvider).token(1);

      // swap token0 and token1 to loanToken
      uint256 before = arb.loanToken.balanceOf(address(this));
      if (amount0 > 0) {
        if (token0 != BNB_ADDRESS) token0.safeApprove(arb.token0Pair, amount0);
        uint256 _value = token0 == BNB_ADDRESS ? amount0 : 0;
        (bool success, ) = arb.token0Pair.call{ value: _value }(arb.swapToken0Data);
        require(success, SwapFailed());
      }

      if (amount1 > 0) {
        if (token1 != BNB_ADDRESS) token1.safeApprove(arb.token1Pair, amount1);
        uint256 _value = token1 == BNB_ADDRESS ? amount1 : 0;
        (bool success, ) = arb.token1Pair.call{ value: _value }(arb.swapToken1Data);
        require(success, SwapFailed());
      }
      uint256 out = arb.loanToken.balanceOf(address(this)) - before;

      if (out < repaidAssets) revert NoProfit();
      if (token0 != BNB_ADDRESS) token0.safeApprove(arb.token0Pair, 0);
      if (token1 != BNB_ADDRESS) token1.safeApprove(arb.token1Pair, 0);
    }

    arb.loanToken.safeApprove(MOOLAH, repaidAssets);
  }

  /// @dev return excess liquidity tokens back to liquidator
  function _sendExcessLiquidityTokens(
    address _smartProvider,
    uint256 beforeToken0Bal,
    uint256 beforeToken1Bal,
    address _liquidator
  ) internal {
    (uint256 token0Bal, uint256 token1Bal) = _liquidityBalances(_smartProvider);

    uint256 token0Leftover = token0Bal - beforeToken0Bal;
    if (token0Leftover > 0) {
      address token0 = ISmartProvider(_smartProvider).token(0);
      if (token0 == BNB_ADDRESS) {
        _liquidator.safeTransferETH(token0Leftover);
      } else {
        token0.safeTransfer(_liquidator, token0Leftover);
      }
    }

    uint256 token1Leftover = token1Bal - beforeToken1Bal;
    if (token1Leftover > 0) {
      address token1 = ISmartProvider(_smartProvider).token(1);
      if (token1 == BNB_ADDRESS) {
        _liquidator.safeTransferETH(token1Leftover);
      } else {
        token1.safeTransfer(_liquidator, token1Leftover);
      }
    }
  }

  function _liquidityBalances(address _smartProvider) internal view returns (uint256, uint256) {
    address token0 = ISmartProvider(_smartProvider).token(0);
    address token1 = ISmartProvider(_smartProvider).token(1);
    uint256 token0Bal = _getBalance(token0);
    uint256 token1Bal = _getBalance(token1);
    return (token0Bal, token1Bal);
  }

  function _getBalance(address _token) internal view returns (uint256) {
    return _token == BNB_ADDRESS ? address(this).balance : _token.balanceOf(address(this));
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /// @dev to accept native tokens from stableswap pools
  receive() external payable {}
}

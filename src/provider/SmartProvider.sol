// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market } from "../moolah/interfaces/IMoolah.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

import { ISmartProvider } from "./interfaces/IProvider.sol";
import { IStableSwap, IStableSwapPoolInfo, StableSwapType } from "../dex/interfaces/IStableSwap.sol";
import { IStableSwapLPCollateral } from "../dex/interfaces/IStableSwapLPCollateral.sol";
import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";

/**
 * @title SmartProvider
 * @author Lista DAO
 * @notice SmartProvider is a contract that allows users to supply collaterals to Lista Lending while simultaneously earning swap fees.
 */
contract SmartProvider is
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  IOracle,
  ISmartProvider
{
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  /* IMMUTABLES */
  IMoolah public immutable MOOLAH;
  /// @dev stableswap LP Collateral token
  address public immutable TOKEN;

  /// @dev stableswap pool
  address public dex;

  /// @dev stableswap pool info contract
  address public dexInfo;

  /// @dev stableswap LP token
  address public dexLP;

  /// @dev resilient oracle address
  address public resilientOracle;

  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /* ------------------ Events ------------------ */
  event SupplyCollateral(
    address indexed onBehalf,
    address indexed collateralToken,
    uint256 collateralAmount,
    uint256 amount0,
    uint256 amount1
  );

  event WithdrawCollateral(
    address indexed collateralToken,
    address indexed onBehalf,
    uint256 collateralAmount,
    uint256 token0Amount,
    uint256 token1Amount,
    address receiver
  );

  event SmartLiquidation(
    address indexed liquidator,
    address indexed collateralToken,
    address dexLP,
    uint256 seizedAssets,
    uint256 minAmount0,
    uint256 minAmount1
  );

  event RedeemLpCollateral(address indexed liquidator, uint256 lpAmount, uint256 token0Amount, uint256 token1Amount);

  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "not moolah");
    _;
  }

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  /// @param dexLPCollateral The address of the stableswap LP collateral token.
  constructor(address moolah, address dexLPCollateral) {
    require(moolah != address(0), ErrorsLib.ZERO_ADDRESS);
    require(dexLPCollateral != address(0), ErrorsLib.ZERO_ADDRESS);

    MOOLAH = IMoolah(moolah);
    TOKEN = dexLPCollateral;

    _disableInitializers();
  }

  /// @param _admin The admin of the contract.
  /// @param _dex The address of the stableswap pool.
  /// @param _dexInfo The address of the stableswap pool info contract.
  /// @param _resilientOracle The address of the resilient oracle.
  function initialize(address _admin, address _dex, address _dexInfo, address _resilientOracle) public initializer {
    require(_admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_dex != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_dexInfo != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_resilientOracle != address(0), ErrorsLib.ZERO_ADDRESS);

    dex = _dex;
    dexInfo = _dexInfo;
    dexLP = IStableSwap(dex).token();
    require(dexLP != address(0), "invalid dex LP token");

    resilientOracle = _resilientOracle;
    _peek(token(0));
    _peek(token(1));

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /**
   * @dev Supplies existing stableswap LP tokens as collateral in Moolah.
   * @param marketParams The market parameters.
   * @param onBehalf The address of the position owner.
   * @param lpAmount The amount of LP tokens to supply.
   */
  function supplyDexLp(MarketParams calldata marketParams, address onBehalf, uint256 lpAmount) external nonReentrant {
    require(lpAmount > 0, "zero lp amount");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");

    // transfer lp from the user
    IERC20(dexLP).safeTransferFrom(msg.sender, address(this), lpAmount);

    // 1:1 mint collateral token
    IStableSwapLPCollateral(TOKEN).mint(address(this), lpAmount);

    // supply collateral to moolah
    IERC20(TOKEN).safeIncreaseAllowance(address(MOOLAH), lpAmount);
    MOOLAH.supplyCollateral(marketParams, lpAmount, onBehalf, "");

    emit SupplyCollateral(onBehalf, TOKEN, lpAmount, 0, 0);
  }

  /**
   * @dev Supplies liquidity to the stableswap pool and uses the resulting LP tokens as collateral in Moolah.
   * @param marketParams The market parameters.
   * @param onBehalf The address of the position owner.
   * @param amount0 The amount of token0 to add as liquidity.
   * @param amount1 The amount of token1 to add as liquidity.
   * @param minLpAmount The minimum amount of LP tokens to receive (slippage tolerance).
   */
  function supplyCollateral(
    MarketParams calldata marketParams,
    address onBehalf,
    uint256 amount0,
    uint256 amount1,
    uint256 minLpAmount
  ) external payable nonReentrant {
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");
    address token0 = token(0);
    address token1 = token(1);

    // validate msg.value, amount0 and amount1
    if (token0 == BNB_ADDRESS) {
      require(amount0 == msg.value, "amount0 should equal msg.value");
    } else if (token1 == BNB_ADDRESS) {
      require(amount1 == msg.value, "amount1 should equal msg.value");
    } else {
      require(msg.value == 0, "msg.value must be 0");
    }
    require(amount0 > 0 || amount1 > 0, "invalid amounts");

    // add liquidity to the stableswap pool
    uint256 actualLpAmount = IERC20(dexLP).balanceOf(address(this));
    if (token0 == BNB_ADDRESS) {
      IERC20(token1).safeIncreaseAllowance(dex, amount1);
      if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
    } else if (token1 == BNB_ADDRESS) {
      IERC20(token0).safeIncreaseAllowance(dex, amount0);
      if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
    } else {
      IERC20(token0).safeIncreaseAllowance(dex, amount0);
      IERC20(token1).safeIncreaseAllowance(dex, amount1);

      if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
      if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
    }
    IStableSwap(dex).add_liquidity{ value: msg.value }([amount0, amount1], minLpAmount);

    // validate the actual LP amount minted
    actualLpAmount = IERC20(dexLP).balanceOf(address(this)) - actualLpAmount;
    require(actualLpAmount > 0, "no lp minted");

    // 1:1 mint collateral token
    IStableSwapLPCollateral(TOKEN).mint(address(this), actualLpAmount);

    // supply collateral to moolah
    IERC20(TOKEN).safeIncreaseAllowance(address(MOOLAH), actualLpAmount);
    MOOLAH.supplyCollateral(marketParams, actualLpAmount, onBehalf, "");

    emit SupplyCollateral(onBehalf, TOKEN, actualLpAmount, amount0, amount1);
  }

  /**
   * @dev Withdraws liquidity according to the tokens proportions in the pool.
   * @param marketParams The market parameters.
   * @param collateralAmount The amount of lp to withdraw.
   * @param minToken0Amount The minimum amount of token0 to receive (slippage tolerance).
   * @param minToken1Amount The minimum amount of token1 to receive (slippage tolerance).
   * @param onBehalf The address of the position owner.
   * @param receiver The address to receive the withdrawn tokens.
   */
  function withdrawCollateral(
    MarketParams calldata marketParams,
    uint256 collateralAmount,
    uint256 minToken0Amount,
    uint256 minToken1Amount,
    address onBehalf,
    address payable receiver
  ) external nonReentrant {
    require(collateralAmount > 0, "zero withdrawal amount");
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(isSenderAuthorized(msg.sender, onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");

    // remove liquidity from the stableswap pool
    (uint256 token0Amount, uint256 token1Amount) = _redeemLp(collateralAmount, minToken0Amount, minToken1Amount);

    // withdraw collateral
    MOOLAH.withdrawCollateral(marketParams, collateralAmount, onBehalf, address(this));

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), collateralAmount);

    if (token0Amount > 0) transferOutTo(0, token0Amount, receiver);
    if (token1Amount > 0) transferOutTo(1, token1Amount, receiver);

    emit WithdrawCollateral(TOKEN, onBehalf, collateralAmount, token0Amount, token1Amount, receiver);
  }

  /**
   * @dev Withdraws liquidity in an imbalanced way, allowing the user to specify exact amounts of token0 and token1 to withdraw.
   * @param marketParams The market parameters.
   * @param token0Amount The exact amount of token0 to withdraw.
   * @param token1Amount The exact amount of token1 to withdraw.
   * @param maxCollateralAmount The maximum amount of collateral (LP tokens) to burn for the withdrawal (slippage tolerance).
   * @param onBehalf The address of the position owner.
   * @param receiver The address to receive the withdrawn tokens.
   */
  function withdrawCollateralImbalance(
    MarketParams calldata marketParams,
    uint256 token0Amount,
    uint256 token1Amount,
    uint256 maxCollateralAmount,
    address onBehalf,
    address payable receiver
  ) external nonReentrant {
    require(token0Amount > 0 || token1Amount > 0, "zero withdrawal amount");
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(isSenderAuthorized(msg.sender, onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");
    require(maxCollateralAmount > 0, "invalid collateral amount");

    // validate slippage before removing liquidity
    uint256[2] memory amounts = [token0Amount, token1Amount];

    // remove liquidity from the stableswap pool
    uint256 actualBurnAmount = IERC20(dexLP).balanceOf(address(this));
    IStableSwap(dex).remove_liquidity_imbalance(amounts, maxCollateralAmount);
    actualBurnAmount = actualBurnAmount - IERC20(dexLP).balanceOf(address(this));

    // withdraw collateral
    MOOLAH.withdrawCollateral(marketParams, actualBurnAmount, onBehalf, address(this));

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), actualBurnAmount);

    if (token0Amount > 0) transferOutTo(0, token0Amount, receiver);
    if (token1Amount > 0) transferOutTo(1, token1Amount, receiver);

    emit WithdrawCollateral(TOKEN, onBehalf, actualBurnAmount, token0Amount, token1Amount, receiver);
  }

  /**
   * @dev Withdraws liquidity in a single token, allowing the user to specify which token to withdraw.
   * @param marketParams The market parameters.
   * @param collateralAmount The amount of lp to withdraw.
   * @param i The index of the token to withdraw (0 or 1).
   * @param minTokenAmount The minimum amount of the specified token i to receive (slippage tolerance).
   * @param onBehalf The address of the position owner.
   * @param receiver The address to receive the withdrawn tokens.
   */
  function withdrawCollateralOneCoin(
    MarketParams calldata marketParams,
    uint256 collateralAmount,
    uint256 i,
    uint256 minTokenAmount,
    address onBehalf,
    address payable receiver
  ) external nonReentrant {
    require(collateralAmount > 0, "zero withdrawal amount");
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(isSenderAuthorized(msg.sender, onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");
    require(i == 0 || i == 1, "invalid token index");

    uint256 actualAmount = getTokenBalance(i);
    IStableSwap(dex).remove_liquidity_one_coin(collateralAmount, i, minTokenAmount);

    actualAmount = getTokenBalance(i) - actualAmount;

    // withdraw collateral
    MOOLAH.withdrawCollateral(marketParams, collateralAmount, onBehalf, address(this));

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), collateralAmount);

    if (actualAmount > 0) transferOutTo(i, actualAmount, receiver);

    emit WithdrawCollateral(
      TOKEN,
      onBehalf,
      collateralAmount,
      i == 0 ? actualAmount : 0,
      i == 1 ? actualAmount : 0,
      receiver
    );
  }

  /**
   * @dev Transfers the specified amount of the token i to the receiver.
   * @param i The index of the token (0 or 1).
   * @param amount The amount of the token to transfer.
   * @param receiver The address to receive the tokens.
   */
  function transferOutTo(uint256 i, uint256 amount, address payable receiver) private {
    address _token = token(i);

    if (_token == BNB_ADDRESS) {
      // if token is BNB, transfer BNB
      (bool success, ) = receiver.call{ value: amount }("");
      require(success, "Transfer BNB failed");
    } else {
      // if token is ERC20, transfer ERC20
      IERC20(_token).safeTransfer(receiver, amount);
    }
  }

  function liquidate(Id id, address borrower) external onlyMoolah {}

  /**
   * @notice Liquidates a position by burning the seized collateral token and removing liquidity from the stableswap pool.
   * @notice The seized tokens (token0 and token1) are then sent to the liquidator.
   * @notice This function assumes that the liquidator has already received the seized collateral token which will be burned.
   * @param liquidator The address of the liquidator.
   * @param lpAmount The amount of collateral to be redeemed (in LP tokens).
   * @param minAmount0 The minimum amount of token0 to receive (slippage tolerance).
   * @param minAmount1 The minimum amount of token1 to receive (slippage tolerance).
   * @return The amount of token0 and token1 redeemed.
   */
  function redeemLpCollateral(
    address payable liquidator, // liquidator contract
    uint256 lpAmount,
    uint256 minAmount0,
    uint256 minAmount1
  ) external returns (uint256, uint256) {
    require(liquidator != address(0), ErrorsLib.ZERO_ADDRESS);
    require(lpAmount > 0, "zero seized assets");
    // burn collateral token sent to the liquidator before
    IStableSwapLPCollateral(TOKEN).burn(liquidator, lpAmount);

    // remove liquidity from the stableswap pool
    (uint256 token0Amount, uint256 token1Amount) = _redeemLp(lpAmount, minAmount0, minAmount1);

    // send token0 and token1 to the liquidator
    if (token0Amount > 0) transferOutTo(0, token0Amount, liquidator);
    if (token1Amount > 0) transferOutTo(1, token1Amount, liquidator);

    emit RedeemLpCollateral(liquidator, lpAmount, token0Amount, token1Amount);
    return (token0Amount, token1Amount);
  }

  function _redeemLp(
    uint256 lpAmount,
    uint256 minAmount0,
    uint256 minAmount1
  ) private returns (uint256 token0Amount, uint256 token1Amount) {
    token0Amount = getTokenBalance(0);
    token1Amount = getTokenBalance(1);

    // redeem lp token
    IStableSwap(dex).remove_liquidity(lpAmount, [minAmount0, minAmount1]);

    // validate the actual token amounts after removing liquidity
    token0Amount = getTokenBalance(0) - token0Amount;
    token1Amount = getTokenBalance(1) - token1Amount;
  }

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  /// @param sender The address of the sender to check.
  /// @param onBehalf The address of the position owner.
  function isSenderAuthorized(address sender, address onBehalf) public view returns (bool) {
    return sender == onBehalf || MOOLAH.isAuthorized(onBehalf, sender);
  }

  /// @param i The index of the token (0 or 1).
  function getTokenBalance(uint256 i) public view returns (uint256) {
    address _token = token(i);

    if (_token == BNB_ADDRESS) {
      return address(this).balance;
    } else {
      return IERC20(_token).balanceOf(address(this));
    }
  }

  /// @dev Returns the address of the token at index `i`.
  function token(uint256 i) public view returns (address) {
    require(i < 2, "Invalid token index");
    return IStableSwap(dex).coins(i);
  }

  /// @dev Returns the price of the token in 8 decimal format.
  function peek(address _token) external view returns (uint256) {
    if (_token == TOKEN || _token == dexLP) {
      // if token is dexLP, return the price of the LP token
      // LP value = min(token0_price, token1_price) * virtual_price
      uint256 minPrice = UtilsLib.min(_peek(token(0)), _peek(token(1)));
      uint256 virtualPrice = IStableSwap(dex).get_virtual_price(); // 1e18
      return (minPrice * virtualPrice) / 1e18;
    }

    return _peek(_token);
  }

  function _peek(address _token) private view returns (uint256) {
    return IOracle(resilientOracle).peek(_token);
  }

  /// @dev Returns the oracle configuration for the specified token.
  function getTokenConfig(address _token) external view returns (TokenConfig memory) {
    if (_token == TOKEN || _token == dexLP) {
      return
        TokenConfig({
          asset: _token,
          oracles: [address(this), address(0), address(0)],
          enableFlagsForOracles: [true, false, false],
          timeDeltaTolerance: 0
        });
    } else {
      return IOracle(resilientOracle).getTokenConfig(_token);
    }
  }

  receive() external payable {
    require(msg.sender == dex, "not dex");
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

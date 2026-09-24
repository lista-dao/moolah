// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { Id, IMoolah, MarketParams } from "../moolah/interfaces/IMoolah.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

import { ISmartProvider } from "./interfaces/IProvider.sol";
import { IStableSwap, IStableSwapPoolInfo } from "../dex/interfaces/IStableSwap.sol";
import { IStableSwapLPCollateral } from "../dex/interfaces/IStableSwapLPCollateral.sol";
import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";
import { ISlisBNBxMinter } from "../utils/interfaces/ISlisBNBx.sol";

/**
 * @title SmartProvider
 * @author Lista DAO
 * @notice Supplies a pro-rata StableSwap LP position as collateral to Lista Lending. The pool charges
 *         no swap fee; a collateral position earns slisBNBx via {ISlisBNBxMinter}.
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

  /// @dev user account > market id > amount of token deposited
  mapping(address => mapping(Id => uint256)) public userMarketDeposit;

  /// @dev user account > total amount of token deposited
  mapping(address => uint256) public userTotalDeposit;

  /// @dev slisBNBxMinter address
  address public slisBNBxMinter;

  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  bytes32 public constant MANAGER = keccak256("MANAGER");

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

  event RedeemLpCollateral(address indexed liquidator, uint256 lpAmount, uint256 token0Amount, uint256 token1Amount);
  event SlisBNBxMinterChanged(address newSlisBNBxMinter);
  event RebalanceFailed(string message);

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

    // sync balances after position change
    _syncPosition(marketParams.id(), onBehalf);

    emit SupplyCollateral(onBehalf, TOKEN, lpAmount, 0, 0);
  }

  /**
   * @dev Withdraw stableswap LP tokens from Moolah.
   * @param marketParams The market parameters.
   * @param onBehalf The address of the position owner.
   * @param assets The amount of LP tokens to withdraw.
   * @param receiver The address to receive the withdrawn LP tokens.
   */
  function withdrawDexLp(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
  ) external nonReentrant {
    require(isSenderAuthorized(msg.sender, onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");

    // withdraw collateral token from moolah
    MOOLAH.withdrawCollateral(marketParams, assets, onBehalf, address(this));

    // sync balances after position change
    _syncPosition(marketParams.id(), onBehalf);

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), assets);

    // transfer lp to user
    IERC20(dexLP).safeTransfer(receiver, assets);
    emit WithdrawCollateral(TOKEN, onBehalf, assets, 0, 0, receiver);
  }

  /**
   * @dev Supplies liquidity to the pool and uses the resulting LP tokens as collateral in Moolah.
   * @notice Converts a pair of token amounts into the pool's share-input API. Both legs are mandatory.
   * @dev An ERC20 leg is an upper bound; only what the shares are worth is pulled. A native leg is not:
   *      `msg.value` must equal it exactly, since there is no refund path. Size a native call from
   *      {IStableSwap-calc_add_liquidity}, not {IStableSwapPoolInfo-calc_coins_amount} — that helper
   *      rounds down where the pool rounds up.
   * @param marketParams The market parameters.
   * @param onBehalf The address of the position owner.
   * @param amount0 The amount of token0 to spend. Upper bound unless token0 is the native coin.
   * @param amount1 The amount of token1 to spend. Upper bound unless token1 is the native coin.
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
    // `_sharesFor` takes the minimum of the two legs, so a one-sided deposit funds zero shares.
    require(amount0 > 0 && amount1 > 0, "both token amounts required");

    // Largest share amount both legs can fully fund at the pool's current reserve ratio.
    uint256 lpAmount = _sharesFor(amount0, amount1);
    require(lpAmount > 0, "no lp minted");
    require(lpAmount >= minLpAmount, "Slippage screwed you");

    // What the pool will actually take. `need[i] <= amount_i` always holds: lpAmount floors the ratio
    // and calc_add_liquidity ceils it back, and ceil(floor(a*s/b)*b/s) <= a for integer a.
    uint256[2] memory need = IStableSwap(dex).calc_add_liquidity(lpAmount);

    uint256 nativeValue;
    if (token0 == BNB_ADDRESS) {
      nativeValue = need[0];
    } else if (token1 == BNB_ADDRESS) {
      nativeValue = need[1];
    }

    // The native leg arrives whole and cannot be partially pulled, so it must match what the pool takes
    // exactly. Reverting on a mismatch keeps the deposit path refund-free, which is what removes the
    // re-entrancy surface entirely. ERC20 legs need no such check: only `need[i]` is ever pulled from
    // the caller.
    require(msg.value == nativeValue, "amounts not proportional");

    // Pull only what the pool takes — the ERC20 legs therefore need no refund at all.
    if (token0 != BNB_ADDRESS && need[0] > 0) {
      IERC20(token0).safeTransferFrom(msg.sender, address(this), need[0]);
      IERC20(token0).safeIncreaseAllowance(dex, need[0]);
    }
    if (token1 != BNB_ADDRESS && need[1] > 0) {
      IERC20(token1).safeTransferFrom(msg.sender, address(this), need[1]);
      IERC20(token1).safeIncreaseAllowance(dex, need[1]);
    }

    uint256 actualLpAmount = IERC20(dexLP).balanceOf(address(this));
    IStableSwap(dex).add_liquidity{ value: nativeValue }(lpAmount, [amount0, amount1]);
    actualLpAmount = IERC20(dexLP).balanceOf(address(this)) - actualLpAmount;
    require(actualLpAmount > 0, "no lp minted");

    // 1:1 mint collateral token
    IStableSwapLPCollateral(TOKEN).mint(address(this), actualLpAmount);

    // supply collateral to moolah
    IERC20(TOKEN).safeIncreaseAllowance(address(MOOLAH), actualLpAmount);
    MOOLAH.supplyCollateral(marketParams, actualLpAmount, onBehalf, "");

    // sync balances after position change
    _syncPosition(marketParams.id(), onBehalf);

    emit SupplyCollateral(onBehalf, TOKEN, actualLpAmount, need[0], need[1]);
  }

  /// @dev Largest LP amount that both `amount0` and `amount1` can fully fund at the current ratio.
  function _sharesFor(uint256 amount0, uint256 amount1) private view returns (uint256) {
    uint256 supply = IERC20(dexLP).totalSupply();
    if (supply == 0) return 0;
    uint256 s0 = (amount0 * supply) / IStableSwap(dex).balances(0);
    uint256 s1 = (amount1 * supply) / IStableSwap(dex).balances(1);
    return s0 < s1 ? s0 : s1;
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

    // sync balances after position change
    _syncPosition(marketParams.id(), onBehalf);

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), collateralAmount);

    if (token0Amount > 0) transferOutTo(0, token0Amount, receiver);
    if (token1Amount > 0) transferOutTo(1, token1Amount, receiver);

    emit WithdrawCollateral(TOKEN, onBehalf, collateralAmount, token0Amount, token1Amount, receiver);
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

  function liquidate(Id id, address borrower) external onlyMoolah {
    // sync balances after position change
    _syncPosition(id, borrower);
  }

  /**
   * @notice Liquidates a position by burning the seized collateral token and removing liquidity from the stableswap pool.
   * @notice The seized tokens (token0 and token1) are then sent to the liquidator.
   * @notice This function assumes that the liquidator has already received the seized collateral token which will be burned.
   * @param lpAmount The amount of collateral to be redeemed (in LP tokens).
   * @param minAmount0 The minimum amount of token0 to receive (slippage tolerance).
   * @param minAmount1 The minimum amount of token1 to receive (slippage tolerance).
   * @return The amount of token0 and token1 redeemed.
   */
  function redeemLpCollateral(
    uint256 lpAmount,
    uint256 minAmount0,
    uint256 minAmount1
  ) external nonReentrant returns (uint256, uint256) {
    require(lpAmount > 0, "zero seized assets");
    // burn collateral token sent to the liquidator before
    IStableSwapLPCollateral(TOKEN).burn(msg.sender, lpAmount);

    // remove liquidity from the stableswap pool
    (uint256 token0Amount, uint256 token1Amount) = _redeemLp(lpAmount, minAmount0, minAmount1);

    // send token0 and token1 to the liquidator
    if (token0Amount > 0) transferOutTo(0, token0Amount, payable(msg.sender));
    if (token1Amount > 0) transferOutTo(1, token1Amount, payable(msg.sender));

    emit RedeemLpCollateral(msg.sender, lpAmount, token0Amount, token1Amount);
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

  function _syncPosition(Id id, address account) private returns (bool, uint256) {
    require(MOOLAH.idToMarketParams(id).collateralToken == TOKEN, "invalid market");
    uint256 userMarketSupplyCollateral = MOOLAH.position(id, account).collateral;
    if (MOOLAH.providers(id, TOKEN) != address(this)) {
      userMarketSupplyCollateral = 0;
    }
    if (userMarketSupplyCollateral >= userMarketDeposit[account][id]) {
      uint256 depositAmount = userMarketSupplyCollateral - userMarketDeposit[account][id];
      userTotalDeposit[account] += depositAmount;
    } else {
      uint256 withdrawAmount = userMarketDeposit[account][id] - userMarketSupplyCollateral;
      userTotalDeposit[account] -= withdrawAmount;
    }
    userMarketDeposit[account][id] = userMarketSupplyCollateral;

    if (slisBNBxMinter == address(0)) {
      return (false, 0);
    } else {
      return ISlisBNBxMinter(slisBNBxMinter).rebalance(account);
    }
  }

  /* ----------------------- slisBNBx Re-balancing ----------------------- */
  /**
   * @dev sync user's slisBNBx balance to retain a consistent ratio with token balance
   * @param _account user address to sync
   */
  function syncUserBalance(Id id, address _account) external {
    (bool rebalanced, ) = _syncPosition(id, _account);
    require(rebalanced, "already synced");
  }

  /**
   * @dev sync multiple user's slisBNBx balance to retain a consistent ratio with token balance
   * @param _accounts user address to sync
   */
  function bulkSyncUserBalance(Id[] calldata ids, address[] calldata _accounts) external {
    for (uint256 i = 0; i < _accounts.length; i++) {
      for (uint256 j = 0; j < ids.length; j++) {
        // sync user's total balance and market balance
        _syncPosition(ids[j], _accounts[i]);
      }
    }
  }

  /// @dev Returns the user's lp collateral value in BNB.
  /// @param account The address of the user.
  function getUserBalanceInBnb(address account) external view returns (uint256) {
    // invoke pool's `get_virtual_price` to ensure the underlying pool not in reentrant state
    IStableSwap(dex).get_virtual_price();

    // how many lp tokens the account has as collateral
    uint256 balance = userTotalDeposit[account];

    // convert lp tokens to bnb value
    uint256[2] memory amounts = IStableSwapPoolInfo(dexInfo).calc_coins_amount(dex, balance);
    uint256 token0Price = _peek(token(0)); // 8 decimals
    uint256 token1Price = _peek(token(1)); // 8 decimals
    uint256 dps0 = (token(0) == BNB_ADDRESS) ? 18 : IERC20Metadata(token(0)).decimals();
    uint256 dps1 = (token(1) == BNB_ADDRESS) ? 18 : IERC20Metadata(token(1)).decimals();

    // calculate lp value in BNB
    uint256 value0 = ((amounts[0] * token0Price) * 1e18) / (10 ** dps0);
    uint256 value1 = ((amounts[1] * token1Price) * 1e18) / (10 ** dps1);
    return (value0 + value1) / _peek(BNB_ADDRESS);
  }

  /// @dev Sets the slisBNBxMinter address.
  function setSlisBNBxMinter(address _slisBNBxMinter) external onlyRole(MANAGER) {
    require(_slisBNBxMinter != address(0), "zero address provided");
    slisBNBxMinter = _slisBNBxMinter;

    emit SlisBNBxMinterChanged(_slisBNBxMinter);
  }

  receive() external payable {
    require(msg.sender == dex, "not dex");
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

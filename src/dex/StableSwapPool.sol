// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStableSwapLP } from "./interfaces/IStableSwapLP.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import "./interfaces/IStableSwap.sol";

contract StableSwapPool is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  PausableUpgradeable,
  IStableSwap
{
  using SafeERC20 for IERC20;

  uint256 public constant N_COINS = 2;

  uint256 public constant MAX_DECIMAL = 18;
  uint256 public constant FEE_DENOMINATOR = 1e10;
  uint256 public constant PRECISION = 1e18;
  uint256[N_COINS] public PRECISION_MUL;
  uint256[N_COINS] public RATES;

  uint256 public constant MAX_ADMIN_FEE = 1e10;
  uint256 public constant MAX_FEE = 5e9;
  uint256 public constant MAX_A = 1e6;
  uint256 public constant MAX_A_CHANGE = 10;
  uint256 public constant MIN_BNB_GAS = 2300;
  uint256 public constant MAX_BNB_GAS = 23000;

  uint256 public constant ADMIN_ACTIONS_DELAY = 3 days;
  uint256 public constant MIN_RAMP_TIME = 1 days;

  address[N_COINS] public coins;
  uint256[N_COINS] public balances;
  /// @dev swap fee; fee * 1e10
  uint256 public fee;
  /// @dev the percentage of the swap fee that is taken as an admin fee. admin_fee * 1e10.
  uint256 public admin_fee;
  /// @dev transfer bnb gas.
  uint256 public bnb_gas;

  address public token;

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  bool public support_BNB;

  uint256 public initial_A;
  uint256 public future_A;
  uint256 public initial_A_time;
  uint256 public future_A_time;

  uint256 public admin_actions_deadline;
  uint256 public future_fee;
  uint256 public future_admin_fee;

  /// @dev resilient oracle; 1e8 precision
  address public oracle;
  /// @dev the threshold for token0 price difference between the pool and the oracle, in 1e18 precision
  uint256 public price0DiffThreshold;
  /// @dev the threshold for token1 price difference between the pool and the oracle, in 1e18 precision
  uint256 public price1DiffThreshold;
  /// @dev can only be initialized by the ss factory
  address public immutable STABLESWAP_FACTORY;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _factory) {
    _disableInitializers();
    STABLESWAP_FACTORY = _factory;
  }

  /**
   * @notice initialize
   * @param _coins: Addresses of ERC20 conracts of coins (c-tokens) involved
   * @param _A: Amplification coefficient multiplied by n * (n - 1)
   * @param _fee: Fee to charge for exchanges
   * @param _admin_fee: Admin fee
   * @param _owner: Owner
   * @param _manager: Manager
   * @param _pauser: Pauser
   * @param _LP: LP address
   * @param _oracle: Resilient oracle address
   */
  function initialize(
    address[N_COINS] memory _coins,
    uint256 _A,
    uint256 _fee,
    uint256 _admin_fee,
    address _owner,
    address _manager,
    address _pauser,
    address _LP,
    address _oracle
  ) public initializer {
    require(msg.sender == STABLESWAP_FACTORY, "Operations: Not factory");
    require(_A <= MAX_A, "_A exceeds maximum");
    require(_fee <= MAX_FEE, "_fee exceeds maximum");
    require(_admin_fee <= MAX_ADMIN_FEE, "_admin_fee exceeds maximum");
    require(_owner != address(0), "ZERO Address");
    require(_manager != address(0), "ZERO Address");
    require(_pauser != address(0), "ZERO Address");
    require(_LP != address(0), "ZERO Address");
    require(_coins.length == N_COINS, "Invalid number of coins");
    require(_oracle != address(0), "ZERO Address for oracle");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    for (uint256 i = 0; i < N_COINS; i++) {
      require(_coins[i] != address(0), "ZERO Address");
      uint256 coinDecimal;
      if (_coins[i] == BNB_ADDRESS) {
        coinDecimal = 18;
        support_BNB = true;
      } else {
        coinDecimal = IERC20Metadata(_coins[i]).decimals();
      }
      require(coinDecimal <= MAX_DECIMAL, "The maximum decimal cannot exceed 18");
      //set PRECISION_MUL and RATES
      PRECISION_MUL[i] = 10 ** (MAX_DECIMAL - coinDecimal);
      RATES[i] = PRECISION * PRECISION_MUL[i];
    }
    coins = _coins;
    initial_A = _A;
    future_A = _A;
    fee = _fee;
    admin_fee = _admin_fee;
    token = _LP;

    oracle = _oracle;
    IOracle(oracle).peek(_coins[0]); // just to check that oracle is working
    IOracle(oracle).peek(_coins[1]); // BNB_ADDR should be config to multi-oracle before deploy
    price0DiffThreshold = 3e16; // 3% threshold for token0 price diff
    price1DiffThreshold = 3e16; // 3% threshold for token1 price diff
    bnb_gas = 4029;

    _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
  }

  function get_A() internal view returns (uint256) {
    //Handle ramping A up or down
    uint256 t1 = future_A_time;
    uint256 A1 = future_A;
    if (block.timestamp < t1) {
      uint256 A0 = initial_A;
      uint256 t0 = initial_A_time;
      // Expressions in uint256 cannot have negative numbers, thus "if"
      if (A1 > A0) {
        return A0 + ((A1 - A0) * (block.timestamp - t0)) / (t1 - t0);
      } else {
        return A0 - ((A0 - A1) * (block.timestamp - t0)) / (t1 - t0);
      }
    } else {
      // when t1 == 0 or block.timestamp >= t1
      return A1;
    }
  }

  function A() external view returns (uint256) {
    return get_A();
  }

  function _xp() internal view returns (uint256[N_COINS] memory result) {
    result = RATES;
    for (uint256 i = 0; i < N_COINS; i++) {
      result[i] = (result[i] * balances[i]) / PRECISION;
    }
  }

  function _xp_mem(uint256[N_COINS] memory _balances) internal view returns (uint256[N_COINS] memory result) {
    result = RATES;
    for (uint256 i = 0; i < N_COINS; i++) {
      result[i] = (result[i] * _balances[i]) / PRECISION;
    }
  }

  function get_D(uint256[N_COINS] memory xp, uint256 amp) internal pure returns (uint256) {
    uint256 S;
    for (uint256 i = 0; i < N_COINS; i++) {
      S += xp[i];
    }
    if (S == 0) {
      return 0;
    }

    uint256 Dprev;
    uint256 D = S;
    uint256 Ann = amp * N_COINS;
    for (uint256 j = 0; j < 255; j++) {
      uint256 D_P = D;
      for (uint256 k = 0; k < N_COINS; k++) {
        D_P = (D_P * D) / (xp[k] * N_COINS); // If division by 0, this will be borked: only withdrawal will work. And that is good
      }
      Dprev = D;
      D = ((Ann * S + D_P * N_COINS) * D) / ((Ann - 1) * D + (N_COINS + 1) * D_P);
      // Equality with the precision of 1
      if (D > Dprev) {
        if (D - Dprev <= 1) {
          break;
        }
      } else {
        if (Dprev - D <= 1) {
          break;
        }
      }
    }
    return D;
  }

  function get_D_mem(uint256[N_COINS] memory _balances, uint256 amp) internal view returns (uint256) {
    return get_D(_xp_mem(_balances), amp);
  }

  function get_virtual_price() external view returns (uint256) {
    /**
     * Returns portfolio virtual price (for calculating profit)
     *     scaled up by 1e18
     */
    uint256 D = get_D(_xp(), get_A());
    /**
     * D is in the units similar to DAI (e.g. converted to precision 1e18)
     *     When balanced, D = n * x_u - total virtual value of the portfolio
     */
    uint256 token_supply = IStableSwapLP(token).totalSupply();
    if (token_supply == 0) return 0;
    return (D * PRECISION) / token_supply;
  }

  function calc_token_amount(uint256[N_COINS] calldata amounts, bool deposit) external view returns (uint256) {
    /**
     * Simplified method to calculate addition or reduction in token supply at
     *     deposit or withdrawal without taking fees into account (but looking at
     *     slippage).
     *     Needed to prevent front-running, not for precise calculations!
     */
    uint256[N_COINS] memory _balances = balances;
    uint256 amp = get_A();
    uint256 D0 = get_D_mem(_balances, amp);
    for (uint256 i = 0; i < N_COINS; i++) {
      if (deposit) {
        _balances[i] += amounts[i];
      } else {
        _balances[i] -= amounts[i];
      }
    }
    uint256 D1 = get_D_mem(_balances, amp);
    uint256 token_amount = IStableSwapLP(token).totalSupply();
    uint256 difference;
    if (deposit) {
      difference = D1 - D0;
    } else {
      difference = D0 - D1;
    }
    return (difference * token_amount) / D0;
  }

  function add_liquidity(
    uint256[N_COINS] calldata amounts,
    uint256 min_mint_amount
  ) external payable whenNotPaused nonReentrant {
    //Amounts is amounts of c-tokens
    if (!support_BNB) {
      require(msg.value == 0, "Inconsistent quantity"); // Avoid sending BNB by mistake.
    }
    uint256[N_COINS] memory fees;
    uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
    uint256 _admin_fee = admin_fee;
    uint256 amp = get_A();

    uint256 token_supply = IStableSwapLP(token).totalSupply();
    //Initial invariant
    uint256 D0;
    uint256[N_COINS] memory old_balances = balances;
    if (token_supply > 0) {
      D0 = get_D_mem(old_balances, amp);
    }
    uint256[N_COINS] memory new_balances = [old_balances[0], old_balances[1]];

    for (uint256 i = 0; i < N_COINS; i++) {
      if (token_supply == 0) {
        require(amounts[i] > 0, "Initial deposit requires all coins");
      }
      // balances store amounts of c-tokens
      new_balances[i] = old_balances[i] + amounts[i];
    }

    // Invariant after change
    uint256 D1 = get_D_mem(new_balances, amp);
    require(D1 > D0, "D1 must be greater than D0");

    // We need to recalculate the invariant accounting for fees
    // to calculate fair user's share
    uint256 D2 = D1;
    if (token_supply > 0) {
      // Only account for fees if we are not the first to deposit
      for (uint256 i = 0; i < N_COINS; i++) {
        uint256 ideal_balance = (D1 * old_balances[i]) / D0;
        uint256 difference;
        if (ideal_balance > new_balances[i]) {
          difference = ideal_balance - new_balances[i];
        } else {
          difference = new_balances[i] - ideal_balance;
        }

        fees[i] = (_fee * difference) / FEE_DENOMINATOR;
        balances[i] = new_balances[i] - ((fees[i] * _admin_fee) / FEE_DENOMINATOR);
        new_balances[i] -= fees[i];
      }
      D2 = get_D_mem(new_balances, amp);
    } else {
      balances = new_balances;
    }

    // Calculate, how much pool tokens to mint
    uint256 mint_amount;
    if (token_supply == 0) {
      mint_amount = D1; // Take the dust if there was any
    } else {
      mint_amount = (token_supply * (D2 - D0)) / D0;
    }
    require(mint_amount >= min_mint_amount, "Slippage screwed you");

    // Take coins from the sender
    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 amount = amounts[i];
      address coin = coins[i];
      transfer_in(coin, amount);
    }

    checkPriceDiff();

    // Mint pool tokens
    IStableSwapLP(token).mint(msg.sender, mint_amount);

    emit AddLiquidity(msg.sender, amounts, fees, D1, token_supply + mint_amount, _admin_fee);
  }

  function get_y(uint256 i, uint256 j, uint256 x, uint256[N_COINS] memory xp_) internal view returns (uint256) {
    // x in the input is converted to the same price/precision
    require((i != j) && (i < N_COINS) && (j < N_COINS), "Illegal parameter");
    uint256 amp = get_A();
    uint256 D = get_D(xp_, amp);
    uint256 c = D;
    uint256 S_;
    uint256 Ann = amp * N_COINS;

    uint256 _x;
    for (uint256 k = 0; k < N_COINS; k++) {
      if (k == i) {
        _x = x;
      } else if (k != j) {
        _x = xp_[k];
      } else {
        continue;
      }
      S_ += _x;
      c = (c * D) / (_x * N_COINS);
    }
    c = (c * D) / (Ann * N_COINS);
    uint256 b = S_ + D / Ann; // - D
    uint256 y_prev;
    uint256 y = D;

    for (uint256 m = 0; m < 255; m++) {
      y_prev = y;
      y = (y * y + c) / (2 * y + b - D);
      // Equality with the precision of 1
      if (y > y_prev) {
        if (y - y_prev <= 1) {
          break;
        }
      } else {
        if (y_prev - y <= 1) {
          break;
        }
      }
    }
    return y;
  }

  function get_dy(uint256 i, uint256 j, uint256 dx) public view returns (uint256) {
    // dx and dy in c-units
    uint256[N_COINS] memory rates = RATES;
    uint256[N_COINS] memory xp = _xp();

    uint256 x = xp[i] + ((dx * rates[i]) / PRECISION);
    uint256 y = get_y(i, j, x, xp);
    uint256 dy = ((xp[j] - y - 1) * PRECISION) / rates[j];
    uint256 _fee = (fee * dy) / FEE_DENOMINATOR;
    return dy - _fee;
  }

  /// @dev return the external oracle price for a given coin in 1e18 precision
  /// @return oraclePrices The prices of the token0 and token1 in 1e18 precision
  function fetchOraclePrice() public view returns (uint256[2] memory oraclePrices) {
    require(oracle != address(0), "Oracle not set");

    oraclePrices[0] = IOracle(oracle).peek(coins[0]) * 1e10;
    oraclePrices[1] = IOracle(oracle).peek(coins[1]) * 1e10;
  }

  /// @dev Check if the price difference between the pool and the oracle exceeds the threshold
  /// @notice This function reverts if the token0 or token1 price difference exceeds the threshold
  function checkPriceDiff() public view {
    // use 1 token_i dx to get swap price
    uint256 dps0 = (coins[0] == BNB_ADDRESS) ? 18 : IERC20Metadata(coins[0]).decimals();
    uint256 dps1 = (coins[1] == BNB_ADDRESS) ? 18 : IERC20Metadata(coins[1]).decimals();
    uint256 dx0 = 10 ** (dps0); // 1 token0
    uint256 dx1 = 10 ** (dps1); // 1 token1

    uint256 dy1 = get_dy(0, 1, dx0); // token1Amount for 1 token0, in original precision
    uint256 dy0 = get_dy(1, 0, dx1); // token0Amount for 1 token1, in original precision

    // normalize dy to 1e18 dps
    uint256 token1Amount = dy1 * PRECISION_MUL[1];
    uint256 token0Amount = dy0 * PRECISION_MUL[0];

    uint256[N_COINS] memory oraclePrices = fetchOraclePrice();

    uint256 price0 = (1e18 * oraclePrices[1]) / token0Amount;
    uint256 price1 = (1e18 * oraclePrices[0]) / token1Amount;

    // Calculate price differences
    uint256 priceDiff0 = (price0 > oraclePrices[0]) ? price0 - oraclePrices[0] : oraclePrices[0] - price0;
    uint256 priceDiff1 = (price1 > oraclePrices[1]) ? price1 - oraclePrices[1] : oraclePrices[1] - price1;

    // Check if price differences exceed thresholds
    require(
      (priceDiff0 * 1e18) <= (oraclePrices[0] * price0DiffThreshold),
      "Price difference for token0 exceeds threshold"
    );

    require(
      (priceDiff1 * 1e18) <= (oraclePrices[1] * price1DiffThreshold),
      "Price difference for token1 exceeds threshold"
    );
  }

  function get_dy_underlying(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
    // dx and dy in underlying units
    uint256[N_COINS] memory xp = _xp();
    uint256[N_COINS] memory precisions = PRECISION_MUL;

    uint256 x = xp[i] + dx * precisions[i];
    uint256 y = get_y(i, j, x, xp);
    uint256 dy = (xp[j] - y - 1) / precisions[j];
    uint256 _fee = (fee * dy) / FEE_DENOMINATOR;
    return dy - _fee;
  }

  /// @dev token0 -> token1: i = 0, j = 1
  /// @dev token1 -> token0: i = 1, j = 0
  function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable whenNotPaused nonReentrant {
    if (!support_BNB) {
      require(msg.value == 0, "Inconsistent quantity"); // Avoid sending BNB by mistake.
    }

    uint256[N_COINS] memory old_balances = balances;
    uint256[N_COINS] memory xp = _xp_mem(old_balances);

    uint256 x = xp[i] + (dx * RATES[i]) / PRECISION;
    uint256 y = get_y(i, j, x, xp);

    uint256 dy = xp[j] - y - 1; //  -1 just in case there were some rounding errors
    uint256 dy_fee = (dy * fee) / FEE_DENOMINATOR;

    // Convert all to real units
    dy = ((dy - dy_fee) * PRECISION) / RATES[j];
    require(dy >= min_dy, "Exchange resulted in fewer coins than expected");

    uint256 dy_admin_fee = (dy_fee * admin_fee) / FEE_DENOMINATOR;
    dy_admin_fee = (dy_admin_fee * PRECISION) / RATES[j];

    // Change balances exactly in same way as we change actual ERC20 coin amounts
    balances[i] = old_balances[i] + dx;
    // When rounding errors happen, we undercharge admin fee in favor of LP
    balances[j] = old_balances[j] - dy - dy_admin_fee;

    // check price diff
    checkPriceDiff();

    address iAddress = coins[i];
    if (iAddress == BNB_ADDRESS) {
      require(dx == msg.value, "Inconsistent quantity");
    } else {
      IERC20(iAddress).safeTransferFrom(msg.sender, address(this), dx);
    }
    address jAddress = coins[j];
    transfer_out(jAddress, dy);
    emit TokenExchange(msg.sender, i, dx, j, dy, dy_fee, dy_admin_fee);
  }

  function remove_liquidity(uint256 _amount, uint256[N_COINS] calldata min_amounts) external nonReentrant {
    uint256 total_supply = IStableSwapLP(token).totalSupply();
    uint256[N_COINS] memory amounts;
    uint256[N_COINS] memory fees; //Fees are unused but we've got them historically in event

    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 value = (balances[i] * _amount) / total_supply;
      require(value >= min_amounts[i], "Withdrawal resulted in fewer coins than expected");
      balances[i] -= value;
      amounts[i] = value;
      transfer_out(coins[i], value);
    }

    checkPriceDiff(); // Check price diff before burning LP tokens

    IStableSwapLP(token).burnFrom(msg.sender, _amount); // dev: insufficient funds

    emit RemoveLiquidity(msg.sender, amounts, fees, total_supply - _amount);
  }

  function remove_liquidity_imbalance(
    uint256[N_COINS] calldata amounts,
    uint256 max_burn_amount
  ) external whenNotPaused nonReentrant {
    uint256 token_supply = IStableSwapLP(token).totalSupply();
    require(token_supply > 0, "dev: zero total supply");
    uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
    uint256 _admin_fee = admin_fee;
    uint256 amp = get_A();

    uint256[N_COINS] memory old_balances = balances;
    uint256[N_COINS] memory new_balances = [old_balances[0], old_balances[1]];
    uint256 D0 = get_D_mem(old_balances, amp);
    for (uint256 i = 0; i < N_COINS; i++) {
      new_balances[i] -= amounts[i];
    }
    uint256 D1 = get_D_mem(new_balances, amp);
    uint256[N_COINS] memory fees;
    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 ideal_balance = (D1 * old_balances[i]) / D0;
      uint256 difference;
      if (ideal_balance > new_balances[i]) {
        difference = ideal_balance - new_balances[i];
      } else {
        difference = new_balances[i] - ideal_balance;
      }
      fees[i] = (_fee * difference) / FEE_DENOMINATOR;
      balances[i] = new_balances[i] - ((fees[i] * _admin_fee) / FEE_DENOMINATOR);
      new_balances[i] -= fees[i];
    }
    uint256 D2 = get_D_mem(new_balances, amp);

    uint256 token_amount = ((D0 - D2) * token_supply) / D0;
    require(token_amount > 0, "token_amount must be greater than 0");
    token_amount += 1; // In case of rounding errors - make it unfavorable for the "attacker"
    require(token_amount <= max_burn_amount, "Slippage screwed you");

    checkPriceDiff(); // Check price diff before burning LP tokens

    IStableSwapLP(token).burnFrom(msg.sender, token_amount); // dev: insufficient funds

    for (uint256 i = 0; i < N_COINS; i++) {
      if (amounts[i] > 0) {
        transfer_out(coins[i], amounts[i]);
      }
    }
    token_supply -= token_amount;
    emit RemoveLiquidityImbalance(msg.sender, amounts, fees, D1, token_supply, _admin_fee);
  }

  function get_y_D(uint256 A_, uint256 i, uint256[N_COINS] memory xp, uint256 D) internal pure returns (uint256) {
    /**
     * Calculate x[i] if one reduces D from being calculated for xp to D
     *
     *     Done by solving quadratic equation iteratively.
     *     x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
     *     x_1**2 + b*x_1 = c
     *
     *     x_1 = (x_1**2 + c) / (2*x_1 + b)
     */
    // x in the input is converted to the same price/precision
    require(i < N_COINS, "dev: i above N_COINS");
    uint256 c = D;
    uint256 S_;
    uint256 Ann = A_ * N_COINS;

    uint256 _x;
    for (uint256 k = 0; k < N_COINS; k++) {
      if (k != i) {
        _x = xp[k];
      } else {
        continue;
      }
      S_ += _x;
      c = (c * D) / (_x * N_COINS);
    }
    c = (c * D) / (Ann * N_COINS);
    uint256 b = S_ + D / Ann;
    uint256 y_prev;
    uint256 y = D;

    for (uint256 k = 0; k < 255; k++) {
      y_prev = y;
      y = (y * y + c) / (2 * y + b - D);
      // Equality with the precision of 1
      if (y > y_prev) {
        if (y - y_prev <= 1) {
          break;
        }
      } else {
        if (y_prev - y <= 1) {
          break;
        }
      }
    }
    return y;
  }

  function _calc_withdraw_one_coin(uint256 _token_amount, uint256 i) internal view returns (uint256, uint256) {
    // First, need to calculate
    // * Get current D
    // * Solve Eqn against y_i for D - _token_amount
    uint256 amp = get_A();
    uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
    uint256[N_COINS] memory precisions = PRECISION_MUL;
    uint256 total_supply = IStableSwapLP(token).totalSupply();

    uint256[N_COINS] memory xp = _xp();

    uint256 D0 = get_D(xp, amp);
    uint256 D1 = D0 - (_token_amount * D0) / total_supply;
    uint256[N_COINS] memory xp_reduced = xp;

    uint256 new_y = get_y_D(amp, i, xp, D1);
    uint256 dy_0 = (xp[i] - new_y) / precisions[i]; // w/o fees

    for (uint256 k = 0; k < N_COINS; k++) {
      uint256 dx_expected;
      if (k == i) {
        dx_expected = (xp[k] * D1) / D0 - new_y;
      } else {
        dx_expected = xp[k] - (xp[k] * D1) / D0;
      }
      xp_reduced[k] -= (_fee * dx_expected) / FEE_DENOMINATOR;
    }
    uint256 dy = xp_reduced[i] - get_y_D(amp, i, xp_reduced, D1);
    dy = (dy - 1) / precisions[i]; // Withdraw less to account for rounding errors

    return (dy, dy_0 - dy);
  }

  function calc_withdraw_one_coin(uint256 _token_amount, uint256 i) external view returns (uint256) {
    (uint256 dy, ) = _calc_withdraw_one_coin(_token_amount, i);
    return dy;
  }

  function remove_liquidity_one_coin(
    uint256 _token_amount,
    uint256 i,
    uint256 min_amount
  ) external whenNotPaused nonReentrant {
    // Remove `_token_amount` of liquidity all in a form of coin i
    (uint256 dy, uint256 dy_fee) = _calc_withdraw_one_coin(_token_amount, i);
    require(dy >= min_amount, "Not enough coins removed");

    balances[i] -= (dy + (dy_fee * admin_fee) / FEE_DENOMINATOR);

    checkPriceDiff(); // Check price diff before burning LP tokens

    IStableSwapLP(token).burnFrom(msg.sender, _token_amount); // dev: insufficient funds
    transfer_out(coins[i], dy);

    emit RemoveLiquidityOne(msg.sender, i, _token_amount, dy, dy_fee, admin_fee);
  }

  function transfer_out(address coin_address, uint256 value) internal {
    if (coin_address == BNB_ADDRESS) {
      _safeTransferBNB(msg.sender, value);
    } else {
      IERC20(coin_address).safeTransfer(msg.sender, value);
    }
  }

  function transfer_in(address coin_address, uint256 value) internal {
    if (coin_address == BNB_ADDRESS) {
      require(value == msg.value, "Inconsistent quantity");
    } else {
      IERC20(coin_address).safeTransferFrom(msg.sender, address(this), value);
    }
  }

  function _safeTransferBNB(address to, uint256 value) internal {
    (bool success, ) = to.call{ gas: bnb_gas, value: value }("");
    require(success, "BNB transfer failed");
  }

  // Admin functions

  function set_bnb_gas(uint256 _bnb_gas) external onlyRole(MANAGER) {
    require(_bnb_gas >= MIN_BNB_GAS && _bnb_gas <= MAX_BNB_GAS, "Illegal gas");
    bnb_gas = _bnb_gas;
    emit SetBNBGas(_bnb_gas);
  }

  function ramp_A(uint256 _future_A, uint256 _future_time) external onlyRole(MANAGER) {
    require(block.timestamp >= initial_A_time + MIN_RAMP_TIME, "dev : too early");
    require(_future_time >= block.timestamp + MIN_RAMP_TIME, "dev: insufficient time");

    uint256 _initial_A = get_A();
    require(_future_A > 0 && _future_A < MAX_A, "_future_A must be between 0 and MAX_A");
    require(
      (_future_A >= _initial_A && _future_A <= _initial_A * MAX_A_CHANGE) ||
        (_future_A < _initial_A && _future_A * MAX_A_CHANGE >= _initial_A),
      "Illegal parameter _future_A"
    );
    initial_A = _initial_A;
    future_A = _future_A;
    initial_A_time = block.timestamp;
    future_A_time = _future_time;

    emit RampA(_initial_A, _future_A, block.timestamp, _future_time);
  }

  function stop_rampget_A() external onlyRole(MANAGER) {
    uint256 current_A = get_A();
    initial_A = current_A;
    future_A = current_A;
    initial_A_time = block.timestamp;
    future_A_time = block.timestamp;
    // now (block.timestamp < t1) is always False, so we return saved A

    emit StopRampA(current_A, block.timestamp);
  }

  function commit_new_fee(uint256 new_fee, uint256 new_admin_fee) external onlyRole(MANAGER) {
    require(admin_actions_deadline == 0, "admin_actions_deadline must be 0"); // dev: active action
    require(new_fee <= MAX_FEE, "dev: fee exceeds maximum");
    require(new_admin_fee <= MAX_ADMIN_FEE, "dev: admin fee exceeds maximum");

    admin_actions_deadline = block.timestamp + ADMIN_ACTIONS_DELAY;
    future_fee = new_fee;
    future_admin_fee = new_admin_fee;

    emit CommitNewFee(admin_actions_deadline, new_fee, new_admin_fee);
  }

  function apply_new_fee() external onlyRole(MANAGER) {
    require(block.timestamp >= admin_actions_deadline, "dev: insufficient time");
    require(admin_actions_deadline != 0, "admin_actions_deadline should not be 0");

    admin_actions_deadline = 0;
    fee = future_fee;
    admin_fee = future_admin_fee;

    emit NewFee(fee, admin_fee);
  }

  function revert_new_parameters() external onlyRole(MANAGER) {
    admin_actions_deadline = 0;
    emit RevertParameters();
  }

  function admin_balances(uint256 i) external view returns (uint256) {
    if (coins[i] == BNB_ADDRESS) {
      return address(this).balance - balances[i];
    } else {
      return IERC20(coins[i]).balanceOf(address(this)) - balances[i];
    }
  }

  function withdraw_admin_fees() external onlyRole(MANAGER) {
    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 value;
      if (coins[i] == BNB_ADDRESS) {
        value = address(this).balance - balances[i];
      } else {
        value = IERC20(coins[i]).balanceOf(address(this)) - balances[i];
      }
      if (value > 0) {
        transfer_out(coins[i], value);
      }
    }
  }

  /// @dev donate admin fees as pool reserves
  function donate_admin_fees() external onlyRole(MANAGER) {
    for (uint256 i = 0; i < N_COINS; i++) {
      if (coins[i] == BNB_ADDRESS) {
        balances[i] = address(this).balance;
      } else {
        balances[i] = IERC20(coins[i]).balanceOf(address(this));
      }
    }
    emit DonateAdminFees();
  }

  function changePriceDiffThreshold(
    uint256 _price0DiffThreshold,
    uint256 _price1DiffThreshold
  ) external onlyRole(MANAGER) {
    require(_price0DiffThreshold <= 1e18, "price0DiffThreshold too high");
    require(_price1DiffThreshold <= 1e18, "price1DiffThreshold too high");
    require(_price0DiffThreshold != price0DiffThreshold || _price1DiffThreshold != price1DiffThreshold, "No change");

    price0DiffThreshold = _price0DiffThreshold;
    price1DiffThreshold = _price1DiffThreshold;
    emit ChangePriceDiffThreshold(_price0DiffThreshold, _price1DiffThreshold);
  }

  /// @dev Pause the contract. Only `remove_liquidity` is allowed.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /// @dev Resume the contract.
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

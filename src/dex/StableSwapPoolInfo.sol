// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IStableSwap, StableSwapType } from "./interfaces/IStableSwap.sol";

contract StableSwapPoolInfo is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  uint256 public constant N_COINS = 2;
  uint256 public constant FEE_DENOMINATOR = 1e10;
  uint256 public constant PRECISION = 1e18;
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin) public initializer {
    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  function token(address _swap) public view returns (IERC20) {
    return IERC20(IStableSwap(_swap).token());
  }

  function balances(address _swap) public view returns (uint256[N_COINS] memory swapBalances) {
    for (uint256 i = 0; i < N_COINS; i++) {
      swapBalances[i] = IStableSwap(_swap).balances(i);
    }
  }

  /**
   * @notice Given an amount of currency i, calculate the amount of currency j that would be added without moving the price
   * @param _swap Address of the swap
   * @param i Index value of the input currency
   * @param amount_i Amount of currency i to convert, in original token i precision
   * @return amount_j Amount of currency j that would be received, in original token j precision
   */
  function calc_amount_i_perfect(address _swap, uint256 i, uint256 amount_i) external view returns (uint256 amount_j) {
    uint256[N_COINS] memory balances = balances(_swap);

    uint256 balance_i = balances[i];
    uint256 balance_j = balances[(i + 1) % N_COINS];

    amount_j = (amount_i * balance_j) / balance_i;
  }

  function RATES(address _swap) public view returns (uint256[N_COINS] memory swapRATES) {
    for (uint256 i = 0; i < N_COINS; i++) {
      swapRATES[i] = IStableSwap(_swap).RATES(i);
    }
  }

  function PRECISION_MUL(address _swap) public view returns (uint256[N_COINS] memory swapPRECISION_MUL) {
    for (uint256 i = 0; i < N_COINS; i++) {
      swapPRECISION_MUL[i] = IStableSwap(_swap).PRECISION_MUL(i);
    }
  }

  function calc_coins_amount(address _swap, uint256 _amount) public view returns (uint256[N_COINS] memory) {
    uint256 total_supply = token(_swap).totalSupply();
    uint256[N_COINS] memory amounts;

    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 value = (IStableSwap(_swap).balances(i) * _amount) / total_supply;
      amounts[i] = value;
    }
    return amounts;
  }

  /// @dev Get the total amount of token0 and token1 held by a liquidity provider
  /// @param _swap Address of the swap
  /// @param _account Address of the liquidity provider
  function get_coins_amount_of(address _swap, address _account) external view returns (uint256[N_COINS] memory) {
    uint256 _amount = token(_swap).balanceOf(_account);
    return calc_coins_amount(_swap, _amount);
  }

  function get_D_mem(address _swap, uint256[N_COINS] memory _balances, uint256 amp) public view returns (uint256) {
    return get_D(_xp_mem(_swap, _balances), amp);
  }

  function get_add_liquidity_mint_amount(address _swap, uint256[N_COINS] memory amounts) public view returns (uint256) {
    IStableSwap swap = IStableSwap(_swap);
    uint256[N_COINS] memory fees;
    uint256 _fee = (swap.fee() * N_COINS) / (4 * (N_COINS - 1));
    uint256 amp = swap.A();

    uint256 token_supply = token(_swap).totalSupply();
    //Initial invariant
    uint256 D0;
    uint256[N_COINS] memory old_balances = balances(_swap);
    if (token_supply > 0) {
      D0 = get_D_mem(_swap, old_balances, amp);
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
    uint256 D1 = get_D_mem(_swap, new_balances, amp);
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
        new_balances[i] -= fees[i];
      }
      D2 = get_D_mem(_swap, new_balances, amp);
    }

    // Calculate, how much pool tokens to mint
    uint256 mint_amount;
    if (token_supply == 0) {
      mint_amount = D1; // Take the dust if there was any
    } else {
      mint_amount = (token_supply * (D2 - D0)) / D0;
    }
    return mint_amount;
  }

  function get_add_liquidity_fee(
    address _swap,
    uint256[N_COINS] memory amounts
  ) external view returns (uint256[N_COINS] memory swapFee, uint256[N_COINS] memory adminFee) {
    IStableSwap swap = IStableSwap(_swap);
    uint256 _fee = (swap.fee() * N_COINS) / (4 * (N_COINS - 1));
    uint256 _admin_fee = swap.admin_fee();
    uint256 amp = swap.A();

    uint256 token_supply = token(_swap).totalSupply();
    //Initial invariant
    uint256 D0;
    uint256[N_COINS] memory old_balances = balances(_swap);

    if (token_supply > 0) {
      D0 = get_D_mem(_swap, old_balances, amp);
    }
    uint256[N_COINS] memory new_balances = [old_balances[0], old_balances[1]];

    for (uint256 i = 0; i < N_COINS; i++) {
      if (token_supply == 0) {
        require(amounts[i] > 0, "Initial deposit requires all coins");
      }
      new_balances[i] = old_balances[i] + amounts[i];
    }

    // Invariant after change
    uint256 D1 = get_D_mem(_swap, new_balances, amp);
    require(D1 > D0, "D1 must be greater than D0");
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
        uint256 coinFee;
        coinFee = (_fee * difference) / FEE_DENOMINATOR;
        swapFee[i] = coinFee;
        adminFee[i] = ((coinFee * _admin_fee) / FEE_DENOMINATOR);
      }
    }
  }

  function get_remove_liquidity_imbalance_fee(
    address _swap,
    uint256[N_COINS] memory amounts
  ) external view returns (uint256[N_COINS] memory swapFee, uint256[N_COINS] memory adminFee) {
    IStableSwap swap = IStableSwap(_swap);
    uint256 _fee = (swap.fee() * N_COINS) / (4 * (N_COINS - 1));
    uint256 _admin_fee = swap.admin_fee();
    uint256 amp = swap.A();

    uint256[N_COINS] memory old_balances = balances(_swap);
    uint256[N_COINS] memory new_balances = [old_balances[0], old_balances[1]];
    uint256 D0 = get_D_mem(_swap, old_balances, amp);
    for (uint256 i = 0; i < N_COINS; i++) {
      new_balances[i] -= amounts[i];
    }
    uint256 D1 = get_D_mem(_swap, new_balances, amp);
    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 ideal_balance = (D1 * old_balances[i]) / D0;
      uint256 difference;
      if (ideal_balance > new_balances[i]) {
        difference = ideal_balance - new_balances[i];
      } else {
        difference = new_balances[i] - ideal_balance;
      }
      uint256 coinFee;
      coinFee = (_fee * difference) / FEE_DENOMINATOR;
      swapFee[i] = coinFee;
      adminFee[i] = ((coinFee * _admin_fee) / FEE_DENOMINATOR);
    }
  }

  function _xp_mem(
    address _swap,
    uint256[N_COINS] memory _balances
  ) public view returns (uint256[N_COINS] memory result) {
    result = RATES(_swap);
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

  function get_y(
    address _swap,
    uint256 i,
    uint256 j,
    uint256 x,
    uint256[N_COINS] memory xp_
  ) internal view returns (uint256) {
    IStableSwap swap = IStableSwap(_swap);
    uint256 amp = swap.A();
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

  function get_exchange_fee(
    address _swap,
    uint256 i,
    uint256 j,
    uint256 dx
  ) external view returns (uint256 exFee, uint256 exAdminFee) {
    IStableSwap swap = IStableSwap(_swap);

    uint256[N_COINS] memory old_balances = balances(_swap);
    uint256[N_COINS] memory xp = _xp_mem(_swap, old_balances);
    uint256[N_COINS] memory rates = RATES(_swap);
    uint256 x = xp[i] + (dx * rates[i]) / PRECISION;
    uint256 y = get_y(_swap, i, j, x, xp);

    uint256 dy = xp[j] - y - 1; //  -1 just in case there were some rounding errors
    uint256 dy_fee = (dy * swap.fee()) / FEE_DENOMINATOR;

    uint256 dy_admin_fee = (dy_fee * swap.admin_fee()) / FEE_DENOMINATOR;
    dy_fee = (dy_fee * PRECISION) / rates[j];
    dy_admin_fee = (dy_admin_fee * PRECISION) / rates[j];
    exFee = dy_fee;
    exAdminFee = dy_admin_fee;
  }

  function _xp(address _swap) internal view returns (uint256[N_COINS] memory result) {
    result = RATES(_swap);
    for (uint256 i = 0; i < N_COINS; i++) {
      result[i] = (result[i] * IStableSwap(_swap).balances(i)) / PRECISION;
    }
  }

  function get_y_D(uint256 A_, uint256 i, uint256[N_COINS] memory xp, uint256 D) internal pure returns (uint256) {
    /**
        Calculate x[i] if one reduces D from being calculated for xp to D

        Done by solving quadratic equation iteratively.
        x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
        x_1**2 + b*x_1 = c

        x_1 = (x_1**2 + c) / (2*x_1 + b)
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

  function _calc_withdraw_one_coin(
    address _swap,
    uint256 _token_amount,
    uint256 i
  ) internal view returns (uint256, uint256) {
    IStableSwap swap = IStableSwap(_swap);
    uint256 amp = swap.A();
    uint256 _fee = (swap.fee() * N_COINS) / (4 * (N_COINS - 1));
    uint256[N_COINS] memory precisions = PRECISION_MUL(_swap);

    uint256[N_COINS] memory xp = _xp(_swap);

    uint256 D0 = get_D(xp, amp);
    uint256 D1 = D0 - (_token_amount * D0) / (token(_swap).totalSupply());
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

  function get_remove_liquidity_one_coin_fee(
    address _swap,
    uint256 _token_amount,
    uint256 i
  ) external view returns (uint256 swapFee, uint256 adminFee) {
    IStableSwap swap = IStableSwap(_swap);
    (, uint256 dy_fee) = _calc_withdraw_one_coin(_swap, _token_amount, i);
    swapFee = dy_fee;
    adminFee = (dy_fee * swap.admin_fee()) / FEE_DENOMINATOR;
  }

  function get_dx(address _swap, uint256 i, uint256 j, uint256 dy, uint256 max_dx) external view returns (uint256) {
    IStableSwap swap = IStableSwap(_swap);
    uint256[N_COINS] memory old_balances = balances(_swap);
    uint256[N_COINS] memory xp = _xp_mem(_swap, old_balances);

    uint256 dy_with_fee = (dy * FEE_DENOMINATOR) / (FEE_DENOMINATOR - swap.fee());
    require(dy_with_fee < old_balances[j], "Excess balance");
    uint256[N_COINS] memory rates = RATES(_swap);
    uint256 y = xp[j] - (dy_with_fee * rates[j]) / PRECISION;
    uint256 x = get_y(_swap, j, i, y, xp);

    uint256 dx = x - xp[i];

    // Convert all to real units
    dx = (dx * PRECISION) / rates[i] + 1; // +1 for round lose.
    require(dx <= max_dx, "Exchange resulted in fewer coins than expected");
    return dx;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

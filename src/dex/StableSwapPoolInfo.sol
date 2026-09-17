// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IStableSwap } from "./interfaces/IStableSwap.sol";

contract StableSwapPoolInfo is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  uint256 public constant N_COINS = 2;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin) public initializer {
    require(admin != address(0), "Zero address");
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
    if (total_supply == 0 || _amount == 0) {
      return amounts;
    }

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

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

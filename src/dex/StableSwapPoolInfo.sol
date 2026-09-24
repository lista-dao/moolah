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

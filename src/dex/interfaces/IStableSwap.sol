// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

uint256 constant N_COINS = 2;

// enum
enum StableSwapType {
  BothERC20, // pool with ERC20 tokens
  Token0Bnb, // pool with token0 as BNB
  Token1Bnb, // pool with token1 as BNB
  Others // unknown type
}

/// @notice Two-asset reserve pool supporting only pro-rata deposits and redemptions.
/// @dev `AddLiquidity` and `RemoveLiquidity` keep their original signatures so existing consumers are
///      unaffected; their `fees` array is always zero and `invariant` is always zero.
interface IStableSwap {
  function support_BNB() external view returns (bool);

  function token() external view returns (address);

  function balances(uint256 i) external view returns (uint256);

  function admin_balances(uint256 i) external view returns (uint256);

  function N_COINS() external view returns (uint256);

  function RATES(uint256 i) external view returns (uint256);

  function coins(uint256 i) external view returns (address);

  function PRECISION_MUL(uint256 i) external view returns (uint256);

  function get_virtual_price() external view returns (uint256);

  function fetchOraclePrice() external view returns (uint256[2] memory);

  /// @notice Reserves required to mint `lpAmount` shares. Shares its formula with {add_liquidity}.
  function calc_add_liquidity(uint256 lpAmount) external view returns (uint256[N_COINS] memory);

  /// @notice First deposit into an empty pool, establishing its reserve ratio. MANAGER only.
  function seed(uint256[N_COINS] memory amounts) external payable;

  /// @notice Mint `lpAmount` shares, pulling exactly the reserves they are worth.
  function add_liquidity(uint256 lpAmount, uint256[N_COINS] memory maxAmounts) external payable;

  /// @notice Burn `lpAmount` shares for a pro-rata slice of both reserves. Callable while paused.
  function remove_liquidity(uint256 lpAmount, uint256[N_COINS] memory minAmounts) external;

  function withdraw_admin_fees() external;

  // events
  event AddLiquidity(
    address indexed provider,
    uint256[N_COINS] token_amounts,
    uint256[N_COINS] fees,
    uint256 invariant,
    uint256 token_supply,
    uint256 admin_fee_rate
  );
  event RemoveLiquidity(
    address indexed provider,
    uint256[N_COINS] token_amounts,
    uint256[N_COINS] fees,
    uint256 token_supply
  );
  event SetBNBGas(uint256 bnb_gas);
  event ChangeOracle(address newOracle);
}

interface IStableSwapPoolInfo {
  function stableSwapType(address stableSwapPool) external view returns (StableSwapType);

  function calc_coins_amount(address stableSwapPool, uint256 _lpAmount) external view returns (uint256[2] memory);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

uint256 constant N_COINS = 2;

// enum
enum StableSwapType {
  BothERC20, // StableSwap with ERC20 tokens
  Token0Bnb, // StableSwap with token0 as BNB
  Token1Bnb, // StableSwap with token1 as BNB
  Others // unknown type
}

interface IStableSwap {
  function support_BNB() external view returns (bool);

  function token() external view returns (address);

  function balances(uint256 i) external view returns (uint256);

  function N_COINS() external view returns (uint256);

  function RATES(uint256 i) external view returns (uint256);

  function coins(uint256 i) external view returns (address);

  function PRECISION_MUL(uint256 i) external view returns (uint256);

  function fee() external view returns (uint256);

  function admin_fee() external view returns (uint256);

  function A() external view returns (uint256);

  function get_virtual_price() external view returns (uint256);

  function fetchOraclePrice() external view returns (uint256[2] memory);

  function checkPriceDiff() external view;

  //  function get_D_mem(uint256[2] memory _balances, uint256 amp) external view returns (uint256);

  //  function get_y(uint256 i, uint256 j, uint256 x, uint256[2] memory xp_) external view returns (uint256);

  function calc_token_amount(uint256[N_COINS] memory amounts, bool _deposit) external view returns (uint256);

  function calc_withdraw_one_coin(uint256 _token_amount, uint256 i) external view returns (uint256);

  function add_liquidity(uint256[N_COINS] memory amounts, uint256 min_mint_amount) external payable;

  function remove_liquidity(uint256 _token_amount, uint256[N_COINS] memory min_amounts) external;

  function remove_liquidity_imbalance(uint256[N_COINS] memory amounts, uint256 max_burn_amount) external;

  function remove_liquidity_one_coin(uint256 _token_amount, uint256 i, uint256 min_amount) external;

  // events
  event TokenExchange(
    address indexed buyer,
    uint256 sold_id,
    uint256 tokens_sold,
    uint256 bought_id,
    uint256 tokens_bought,
    uint256 swap_fee,
    uint256 admin_fee
  );
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
  event RemoveLiquidityOne(
    address indexed provider,
    uint256 index,
    uint256 token_amount,
    uint256 coin_amount,
    uint256 fee,
    uint256 admin_fee_rate
  );
  event RemoveLiquidityImbalance(
    address indexed provider,
    uint256[N_COINS] token_amounts,
    uint256[N_COINS] fees,
    uint256 invariant,
    uint256 token_supply,
    uint256 admin_fee_rate
  );
  event CommitNewFee(uint256 indexed deadline, uint256 fee, uint256 admin_fee);
  event NewFee(uint256 fee, uint256 admin_fee);
  event RampA(uint256 old_A, uint256 new_A, uint256 initial_time, uint256 future_time);
  event StopRampA(uint256 A, uint256 t);
  event SetBNBGas(uint256 bnb_gas);
  event RevertParameters();
  event DonateAdminFees();
  event ChangePriceDiffThreshold(uint256 price0DiffThreshold, uint256 price1DiffThreshold);
  event ChangeOracle(address newOracle);
}

interface IStableSwapPoolInfo {
  function stableSwapType(address stableSwapPool) external view returns (StableSwapType);

  function get_add_liquidity_mint_amount(
    address stableSwapPool,
    uint256[2] memory amounts
  ) external view returns (uint256);

  function calc_coins_amount(address stableSwapPool, uint256 _lpAmount) external view returns (uint256[2] memory);
}

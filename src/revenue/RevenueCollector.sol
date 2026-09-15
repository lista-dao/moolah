// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IListaV2Factory } from "../dex/interfaces/IListaV2Factory.sol";
import { IListaV2Pair } from "../dex/interfaces/IListaV2Pair.sol";
import { IStableSwap } from "../dex/interfaces/IStableSwap.sol";
import { ILiquidator } from "../liquidator/ILiquidator.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";

/**
 * @title RevenueCollector
 * @notice The RevenueCollector contract is responsible for collecting admin fees from stable swap pools and liquidation revenues from liquidator contracts.
 */
contract RevenueCollector is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeERC20 for IERC20;

  /// @dev Sets of stable swap pools
  EnumerableSet.AddressSet private stableSwapPools;

  /// @dev Sets of liquidator contracts
  EnumerableSet.AddressSet private liquidators;

  /// @dev The Lista V2 factory whose pairs are redeemable by this collector
  address public v2Factory;

  /// @dev Manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");
  /// @dev Bot role
  bytes32 public constant BOT = keccak256("BOT");

  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @dev Max length for batch operations
  uint256 public constant MAX_LENGTH = 30;

  /// @dev A single V2 LP redemption: burn `lpToken`, requiring at least `minAmount0` / `minAmount1` out
  struct V2LpRedemption {
    address lpToken;
    uint256 minAmount0;
    uint256 minAmount1;
  }

  event StableSwapPoolUpdated(address indexed pool, bool addPool);
  event LiquidatorUpdated(address indexed liquidator, bool addLiquidator);
  event StableSwapFeeCollected(address indexed pool);
  event LiquidationFeeCollected(address indexed liquidator, address indexed asset, uint256 amount);
  event EmergencyWithdraw(address indexed asset, uint256 amount, address indexed to);
  event VaultFeeAccrued(address indexed vault);
  event V2FactoryUpdated(address indexed oldFactory, address indexed newFactory);
  event V2LpRedeemed(
    address indexed lpToken,
    uint256 lpAmount,
    address indexed token0,
    uint256 amount0,
    address indexed token1,
    uint256 amount1
  );

  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializer
   * @param admin The admin address
   * @param manager The manager address
   * @param bot The bot address
   * @param pools The list of stable swap pools
   * @param _liquidators The liquidator contracts
   */
  function initialize(
    address admin,
    address manager,
    address bot,
    address[] calldata pools,
    address[] calldata _liquidators
  ) external initializer {
    require(admin != address(0), "zero address");
    require(manager != address(0), "zero address");
    require(bot != address(0), "zero address");

    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);

    for (uint256 i = 0; i < pools.length; i++) {
      require(pools[i] != address(0), "zero address");
      require(stableSwapPools.add(pools[i]), "already added");
      emit StableSwapPoolUpdated(pools[i], true);
    }

    for (uint256 i = 0; i < _liquidators.length; i++) {
      require(_liquidators[i] != address(0), "zero address");
      require(liquidators.add(_liquidators[i]), "already added");
      emit LiquidatorUpdated(_liquidators[i], true);
    }
  }

  /**
   * @dev Claims admin fees from stable swap pools
   * @param pools The list of stable swap pools to claim fees from
   */
  function batchClaimDexFees(address[] calldata pools) external onlyRole(BOT) {
    require(pools.length > 0 && pools.length <= MAX_LENGTH, "invalid length");

    for (uint256 i = 0; i < pools.length; i++) {
      _claimDexFee(pools[i]);
    }
  }

  /**
   * @dev Claims admin fees from a stable swap pool
   * @param pool The address of the stable swap pool
   */
  function claimDexFee(address pool) external onlyRole(BOT) {
    _claimDexFee(pool);
  }

  function _claimDexFee(address pool) internal {
    require(stableSwapPools.contains(pool), "not whitelisted pool");
    IStableSwap(pool).withdraw_admin_fees();

    emit StableSwapFeeCollected(pool);
  }

  /**
   * @dev Triggers fee accrual on Moolah vaults by depositing 0 assets.
   * A zero-asset deposit mints no shares but runs the vault's `_accrueFee` logic,
   * realizing accrued fees to the vault's fee recipient.
   * @param vaults The list of Moolah vaults to accrue fees on
   */
  function batchAccrueVaultFees(address[] calldata vaults) external onlyRole(BOT) {
    require(vaults.length > 0 && vaults.length <= MAX_LENGTH, "invalid length");

    for (uint256 i = 0; i < vaults.length; i++) {
      _accrueVaultFee(vaults[i]);
    }
  }

  /**
   * @dev Triggers fee accrual on a single Moolah vault by depositing 0 assets.
   * @param vault The address of the Moolah vault
   */
  function accrueVaultFee(address vault) external onlyRole(BOT) {
    _accrueVaultFee(vault);
  }

  function _accrueVaultFee(address vault) internal {
    IMoolahVault(vault).deposit(0, address(this));

    emit VaultFeeAccrued(vault);
  }

  /**
   * @notice Claims revenues from liquidator contracts for multiple assets.
   * @param liquidator The address of the liquidator
   * @param assets The list of assets
   * @param amounts The list of amounts corresponding to each asset
   */
  function claimLiquidationFees(
    address liquidator,
    address[] calldata assets,
    uint256[] calldata amounts
  ) external onlyRole(BOT) {
    require(assets.length == amounts.length, "length mismatch");
    require(assets.length > 0 && assets.length <= MAX_LENGTH, "invalid length");

    for (uint256 i = 0; i < assets.length; i++) {
      _claimLiquidationFee(liquidator, assets[i], amounts[i]);
    }
  }

  /**
   * @dev Claims fee for a single asset from liquidator contract
   * @param _liquidator The address of the liquidator
   * @param asset The address of the asset to claim
   * @param amount The amount to claim
   */
  function claimLiquidationFee(address _liquidator, address asset, uint256 amount) external onlyRole(BOT) {
    _claimLiquidationFee(_liquidator, asset, amount);
  }

  function _claimLiquidationFee(address _liquidator, address asset, uint256 amount) internal {
    require(liquidators.contains(_liquidator), "not whitelisted liquidator");
    require(asset != address(0), "zero address");
    require(amount > 0, "invalid amount");

    if (asset != BNB_ADDRESS) {
      ILiquidator(_liquidator).withdrawERC20(asset, amount);
    } else {
      ILiquidator(_liquidator).withdrawETH(amount);
    }

    emit LiquidationFeeCollected(_liquidator, asset, amount);
  }

  /**
   * @dev Redeems the full balance of multiple Lista V2 LP tokens
   * @param redemptions The list of redemptions to perform
   */
  function batchRedeemV2Lps(V2LpRedemption[] calldata redemptions) external onlyRole(BOT) {
    require(redemptions.length > 0 && redemptions.length <= MAX_LENGTH, "invalid length");

    for (uint256 i = 0; i < redemptions.length; i++) {
      _redeemV2Lp(redemptions[i]);
    }
  }

  /**
   * @dev Redeems the full balance of a Lista V2 LP token into token0 / token1
   * @param redemption The LP token to redeem and its minimum acceptable output
   */
  function redeemV2Lp(V2LpRedemption calldata redemption) external onlyRole(BOT) {
    _redeemV2Lp(redemption);
  }

  /// @dev No-op on zero balance, so a batch never fails on an empty pair
  function _redeemV2Lp(V2LpRedemption calldata redemption) internal {
    require(v2Factory != address(0), "v2 factory not set");

    address lpToken = redemption.lpToken;
    (address token0, address token1) = _validateV2Lp(lpToken);

    uint256 lpAmount = IERC20(lpToken).balanceOf(address(this));
    if (lpAmount == 0) {
      return;
    }

    // the pair burns the LP it holds, so send it there first
    IERC20(lpToken).safeTransfer(lpToken, lpAmount);
    (uint256 amount0, uint256 amount1) = IListaV2Pair(lpToken).burn(address(this));
    require(amount0 >= redemption.minAmount0 && amount1 >= redemption.minAmount1, "insufficient output");

    emit V2LpRedeemed(lpToken, lpAmount, token0, amount0, token1, amount1);
  }

  /**
   * @dev Authorizes an LP token by provenance instead of a whitelist: the pair must be registered in
   * `v2Factory`, and that factory must pay its protocol fee LP to this collector.
   */
  function _validateV2Lp(address lpToken) internal view returns (address token0, address token1) {
    IListaV2Factory factory = IListaV2Factory(v2Factory);

    token0 = IListaV2Pair(lpToken).token0();
    token1 = IListaV2Pair(lpToken).token1();

    require(factory.getPair(token0, token1) == lpToken, "invalid lp token");
    require(factory.feeTo() == address(this), "not fee recipient");
  }

  /// @dev To receive BNB
  receive() external payable {}

  //// ----------------------------- Admin Functions ----------------------------- ////

  function updateStableSwapPool(address pool, bool addPool) external onlyRole(MANAGER) {
    require(pool != address(0), "zero address");

    if (addPool) {
      require(stableSwapPools.add(pool), "already added");
    } else {
      require(stableSwapPools.remove(pool), "not exists");
    }

    emit StableSwapPoolUpdated(pool, addPool);
  }

  function updateLiquidator(address liquidator, bool addLiquidator) external onlyRole(MANAGER) {
    require(liquidator != address(0), "zero address");

    if (addLiquidator) {
      require(liquidators.add(liquidator), "already added");
    } else {
      require(liquidators.remove(liquidator), "not exists");
    }

    emit LiquidatorUpdated(liquidator, addLiquidator);
  }

  function setV2Factory(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(factory != address(0), "zero address");
    require(factory != v2Factory, "already set");

    emit V2FactoryUpdated(v2Factory, factory);
    v2Factory = factory;
  }

  function emergencyWithdraw(address asset, uint256 amount, address to) external onlyRole(MANAGER) {
    require(to != address(0), "zero address");
    require(amount > 0, "invalid amount");

    if (asset != BNB_ADDRESS) {
      IERC20(asset).safeTransfer(to, amount);
    } else {
      (bool success, ) = to.call{ value: amount }("");
      require(success, "BNB transfer failed");
    }

    emit EmergencyWithdraw(asset, amount, to);
  }

  //// ----------------------------- View Functions ----------------------------- ////
  function isStableSwapPool(address pool) external view returns (bool) {
    return stableSwapPools.contains(pool);
  }

  function getStableSwapPools() external view returns (address[] memory) {
    return stableSwapPools.values();
  }

  function isLiquidator(address liquidator) external view returns (bool) {
    return liquidators.contains(liquidator);
  }

  function getLiquidators() external view returns (address[] memory) {
    return liquidators.values();
  }

  /**
   * @dev Previews `redeemV2Lp`. Amounts are estimated from current reserves and total supply,
   * so they may drift if the pair mints fee LP on burn or reserves move beforehand.
   * @param lpToken The address of the Lista V2 LP token (the V2 pair)
   */
  function previewRedeemV2Lp(
    address lpToken
  ) external view returns (uint256 lpAmount, address token0, uint256 amount0, address token1, uint256 amount1) {
    require(v2Factory != address(0), "v2 factory not set");

    (token0, token1) = _validateV2Lp(lpToken);
    lpAmount = IERC20(lpToken).balanceOf(address(this));

    IListaV2Pair pair = IListaV2Pair(lpToken);
    uint256 totalSupply = pair.totalSupply();
    if (lpAmount == 0 || totalSupply == 0) {
      return (lpAmount, token0, 0, token1, 0);
    }

    (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
    amount0 = (lpAmount * reserve0) / totalSupply;
    amount1 = (lpAmount * reserve1) / totalSupply;
  }

  /**
   * @dev Previews the claim of admin fees from a stable swap pool
   * @param pool The address of the stable swap pool
   * @return adminFees The list of admin fees for each coin in the pool
   * @return prices The list of oracle prices for each coin in the pool (in 1e18 precision)
   */
  function previewClaimDexFee(
    address pool
  ) external view returns (uint256[2] memory adminFees, uint256[2] memory prices) {
    require(stableSwapPools.contains(pool), "not whitelisted pool");
    IStableSwap stableSwap = IStableSwap(pool);

    for (uint256 i = 0; i < 2; i++) {
      adminFees[i] = stableSwap.admin_balances(i);
    }
    prices = stableSwap.fetchOraclePrice(); // oracle prices in 1e18 precision

    return (adminFees, prices);
  }

  /**
   * @dev Previews the claim without actually withdrawing the liquidation revenues from the liquidator contract.
   * Checks if the liquidator has enough balance of the asset to claim the specified amount.
   * @param liquidator The address of the liquidator
   * @param asset The address of the asset to claim
   * @param amount The amount to claim
   * @return success True if the liquidator has enough balance to claim the specified amount, false otherwise
   */
  function previewClaimLiquidationFee(address liquidator, address asset, uint256 amount) external view returns (bool) {
    if (!liquidators.contains(liquidator) || asset == address(0) || amount == 0) {
      return false;
    }

    if (asset != BNB_ADDRESS) {
      return IERC20(asset).balanceOf(liquidator) >= amount;
    } else {
      return address(liquidator).balance >= amount;
    }
  }

  //// ----------------------------- Upgrade Functions ----------------------------- ////
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

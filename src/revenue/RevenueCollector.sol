// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { IStableSwap } from "../dex/interfaces/IStableSwap.sol";
import { ILiquidator } from "../liquidator/ILiquidator.sol";

/**
 * @title RevenueCollector
 * @notice The RevenueCollector contract is responsible for collecting admin fees from stable swap pools and liquidation fees from liquidator contracts.
 */
contract RevenueCollector is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @dev Sets of stable swap pools
  EnumerableSet.AddressSet private stableSwapPools;

  /// @dev Sets of liquidator contracts
  EnumerableSet.AddressSet private liquidators;

  /// @dev Manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");
  /// @dev Bot role
  bytes32 public constant BOT = keccak256("BOT");

  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @dev Max length for batch operations
  uint256 public constant MAX_LENGTH = 30;

  event StableSwapPoolUpdated(address indexed pool, bool addPool);
  event LiquidatorUpdated(address indexed liquidator, bool addLiquidator);

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
      stableSwapPools.add(pools[i]);
      emit StableSwapPoolUpdated(pools[i], true);
    }

    for (uint256 i = 0; i < _liquidators.length; i++) {
      require(_liquidators[i] != address(0), "zero address");
      liquidators.add(_liquidators[i]);
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
  }

  /**
   * @notice Claims fees from liquidator contract
   * @param liquidator The address of the liquidator
   * @param assets The list of assets
   * @param amounts The list of amounts corresponding to each asset
   */
  function claimLiquidationFees(
    address liquidator,
    address[] calldata assets,
    uint256[] calldata amounts
  ) external onlyRole(BOT) {
    require(liquidators.contains(liquidator), "not whitelisted liquidator");
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

  function emergencyWithdraw(address asset, uint256 amount, address to) external onlyRole(MANAGER) {
    require(to != address(0), "zero address");
    require(amount > 0, "invalid amount");

    if (asset != BNB_ADDRESS) {
      SafeERC20.safeTransfer(IERC20(asset), to, amount);
    } else {
      payable(to).transfer(amount);
    }
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
   * @dev Previews the claim of admin fees from a stable swap pool
   * @param pool The address of the stable swap pool
   * @return adminFees The list of admin fees for each coin in the pool
   * @return prices The list of oracle prices for each coin in the pool (in 1e18 precision)
   */
  function previewClaimDexFee(
    address pool
  ) external view returns (uint256[2] memory adminFees, uint256[2] memory prices) {
    IStableSwap stableSwap = IStableSwap(pool);

    for (uint256 i = 0; i < 2; i++) {
      adminFees[i] = stableSwap.admin_balances(i);
    }
    prices = stableSwap.fetchOraclePrice(); // oracle prices in 1e18 precision

    return (adminFees, prices);
  }

  /**
   * @dev Previews the claim without actually withdrawing the fees.
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

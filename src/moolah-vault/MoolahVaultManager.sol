// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Id, IMoolah, Position, MarketParams } from "../moolah/interfaces/IMoolah.sol";
import { IMoolahVault, MarketAllocation, MarketConfig } from "./interfaces/IMoolahVault.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { MathLib } from "../moolah/libraries/MathLib.sol";

import { MoolahBalancesLib } from "../moolah/libraries/periphery/MoolahBalancesLib.sol";

contract MoolahVaultManager is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using MathLib for uint256;
  using MoolahBalancesLib for IMoolah;
  using SafeERC20 for IERC20;

  /// @dev Mapping to track whitelisted vaults. Only whitelisted vaults can have markets removed.
  mapping(address => bool) public vaultWhitelist;
  /// @dev The address that will receive withdrawn tokens from this contract.
  address public receiver;
  /// @dev The maximum supply value (in USD with 8 decimals) for a market to be removed.
  uint256 public maxSupplyValue;

  /// @dev The Moolah contract instance.
  IMoolah public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role

  event WhitelistUpdated(address indexed vault, bool status);
  event ReceiverUpdated(address indexed newReceiver);
  event MarketRemovedFromVault(address indexed vault, Id indexed marketId, uint256 supplyAmount, uint256 supplyShares);
  event WithdrawnFromMoolah(Id indexed marketId, uint256 amount, uint256 shares);
  event TokenWithdrawn(address indexed token, uint256 amount);
  event MaxSupplyValueUpdated(uint256 newMaxSupplyValue);

  /// @dev Constructor that sets the Moolah contract address.
  /// @param _moolah The address of the Moolah contract.
  constructor(address _moolah) {
    require(_moolah != address(0), "ZeroAddress");
    _disableInitializers();
    MOOLAH = IMoolah(_moolah);
  }

  /// @dev Initializes the contract.
  /// @param admin The new admin of the contract.
  /// @param manager The manager who can set vault whitelist and withdraw tokens.
  /// @param bot The bot who can call removeMarketFromVault and withdrawFromMoolah
  /// @param _receiver The initial receiver of withdrawn tokens.
  /// @param _maxSupplyValue The initial maximum supply value for a market to be removed.
  function initialize(
    address admin,
    address manager,
    address bot,
    address _receiver,
    uint256 _maxSupplyValue
  ) public initializer {
    require(admin != address(0), "ZeroAddress");
    require(manager != address(0), "ZeroAddress");
    require(bot != address(0), "ZeroAddress");
    require(_receiver != address(0), "ZeroAddress");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);

    receiver = _receiver;
    maxSupplyValue = _maxSupplyValue;
  }

  /// @dev Removes a market from a vault by reallocating its supply to another market and setting its cap to 0.
  /// @param vault The address of the vault to remove the market from.
  /// @param id The ID of the market to remove.
  function removeMarketFromVault(address vault, Id id) external onlyRole(BOT) {
    require(vaultWhitelist[vault], "Vault not whitelisted");
    // query market params and expected supply assets
    MarketParams memory marketParams = MOOLAH.idToMarketParams(id);
    uint256 vaultSupplyAssets = MOOLAH.expectedSupplyAssets(marketParams, vault);
    uint256 availableAssets = MOOLAH.expectedTotalSupplyAssets(marketParams) -
      MOOLAH.expectedTotalBorrowAssets(marketParams);
    uint256 supplyAssets = vaultSupplyAssets > availableAssets ? vaultSupplyAssets - availableAssets : 0;
    require(getValue(marketParams, supplyAssets) <= maxSupplyValue, "Exceed max supply value");
    uint256 actualSupplyAssets;
    uint256 actualSupplyShares;
    if (supplyAssets > 0) {
      // supply loan token to moolah
      IERC20(marketParams.loanToken).safeIncreaseAllowance(address(MOOLAH), supplyAssets + 1);
      (actualSupplyAssets, actualSupplyShares) = MOOLAH.supply(marketParams, supplyAssets + 1, 0, address(this), "");
      IERC20(marketParams.loanToken).forceApprove(address(MOOLAH), 0);
    }

    // reallocate all assets to another markets
    uint256 supplyIdx = type(uint256).max;
    MarketAllocation[] memory allocations = new MarketAllocation[](2);
    allocations[0] = MarketAllocation({ marketParams: marketParams, assets: 0 });
    uint256 supplyQueueLength = IMoolahVault(vault).supplyQueueLength();
    Id[] memory newSupplyQueue = new Id[](supplyQueueLength - 1);
    for ((uint256 i, uint256 j) = (0, 0); i < supplyQueueLength; i++) {
      Id marketId = IMoolahVault(vault).supplyQueue(i);
      if (Id.unwrap(id) == Id.unwrap(marketId)) {
        supplyIdx = i;
        continue;
      }
      if (_getRemainCap(IMoolahVault(vault), marketId) >= vaultSupplyAssets && allocations[1].assets == 0) {
        allocations[1] = MarketAllocation({
          marketParams: MOOLAH.idToMarketParams(marketId),
          assets: type(uint256).max
        });
      }
      newSupplyQueue[j] = marketId;
      j++;
    }
    require(supplyIdx != type(uint256).max, "Not in supply queue");
    if (vaultSupplyAssets > 0) {
      require(allocations[1].assets > 0, "No market has enough cap");
      IMoolahVault(vault).reallocate(allocations);
    }

    // set cap to 0 to disable the market
    IMoolahVault(vault).setCap(marketParams, 0);

    // remove from withdraw queue
    uint256 withdrawQueueLength = IMoolahVault(vault).withdrawQueueLength();
    uint256[] memory withdrawIdxs = new uint256[](withdrawQueueLength - 1);
    for ((uint256 i, uint256 j) = (0, 0); i < withdrawQueueLength; i++) {
      Id marketId = IMoolahVault(vault).withdrawQueue(i);
      if (Id.unwrap(id) == Id.unwrap(marketId)) {
        continue;
      }
      withdrawIdxs[j] = i;
      j++;
    }
    IMoolahVault(vault).updateWithdrawQueue(withdrawIdxs);

    // remove from supply queue
    IMoolahVault(vault).setSupplyQueue(newSupplyQueue);

    emit MarketRemovedFromVault(vault, id, actualSupplyAssets, actualSupplyShares);
  }

  /// @dev Withdraws all supplied assets of a market from Moolah to this contract.
  function withdrawFromMoolah(Id id, uint256 assets, uint256 shares) external onlyRole(BOT) {
    // query market params and expected supply assets
    require(assets > 0 || shares > 0, "zero assets and shares");

    MarketParams memory marketParams = MOOLAH.idToMarketParams(id);
    // withdraw loan token from moolah
    (uint256 assets, uint256 shares) = MOOLAH.withdraw(marketParams, assets, shares, address(this), address(this));
    emit WithdrawnFromMoolah(id, assets, shares);
  }

  /// @dev Sets the whitelist status for a list of vaults.
  /// @param vaults The list of vault addresses.
  /// @param status The whitelist status to set (true for whitelisted, false for not whitelisted).
  function batchSetVaultWhitelist(address[] calldata vaults, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < vaults.length; i++) {
      address vault = vaults[i];
      require(vault != address(0), "ZeroAddress");
      require(vaultWhitelist[vault] != status, "Already set");
      vaultWhitelist[vault] = status;

      emit WhitelistUpdated(vault, status);
    }
  }

  /// @dev Sets the receiver address for withdrawn tokens.
  /// @param _receiver The address to set as the receiver of withdrawn tokens.
  function setReceiver(address _receiver) external onlyRole(MANAGER) {
    require(_receiver != address(0), "ZeroAddress");
    require(_receiver != receiver, "Already set");
    require(_receiver != address(this), "Receiver cannot be this contract");
    receiver = _receiver;

    emit ReceiverUpdated(_receiver);
  }

  /// @dev Withdraws token from this contract to the receiver address.
  function withdrawToken(address token) external onlyRole(BOT) {
    require(receiver != address(0), "Receiver not set");
    uint256 amount = IERC20(token).balanceOf(address(this));
    IERC20(token).safeTransfer(receiver, amount);

    emit TokenWithdrawn(token, amount);
  }

  /// @dev Sets the maximum supply value for a market can be removed.
  /// @param _maxSupplyValue The maximum supply value to set.
  function setMaxSupplyValue(uint256 _maxSupplyValue) external onlyRole(MANAGER) {
    require(maxSupplyValue != _maxSupplyValue, "Already set");
    maxSupplyValue = _maxSupplyValue;

    emit MaxSupplyValueUpdated(_maxSupplyValue);
  }

  function getValue(MarketParams memory marketParams, uint256 amount) public view returns (uint256) {
    uint256 price = IOracle(marketParams.oracle).peek(marketParams.loanToken);
    uint8 decimals = IERC20Metadata(marketParams.loanToken).decimals();
    return amount.mulDivDown(price, 10 ** decimals);
  }

  function _getRemainCap(IMoolahVault vault, Id id) private view returns (uint256) {
    MarketParams memory marketParams = MOOLAH.idToMarketParams(id);
    uint256 supplyAssets = MOOLAH.expectedSupplyAssets(marketParams, address(vault));
    MarketConfig memory config = vault.config(id);
    if (config.cap <= supplyAssets) {
      return 0;
    }
    return config.cap - supplyAssets;
  }

  /// @dev Authorizes an upgrade of the contract.
  /// @param newImplementation The address of the new implementation.
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

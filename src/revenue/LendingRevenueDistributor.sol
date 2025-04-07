//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";

/// @title Lending Revenue Distributor
/// @notice Distribute Lending Vault revenue to the revenueReceiver
contract LendingRevenueDistributor is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  /// @dev the percentage of revenue to send to the revenueReceiver; the rest goes to the risk fund
  /// @dev 10000 = 100%
  uint256 public distributePercentage;

  /// @dev address to receive the revenue
  address public revenueReceiver;

  /// @dev address to receive the risk fund
  address public riskFundReceiver;

  uint256 private constant DENOMINATOR = 10000;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  event Distributed(
    address indexed asset,
    address revenueReceiver,
    uint256 revenueAmount,
    address riskFundReceiver,
    uint256 riskFundAmount
  );

  event EmergencyWithdrawn(address indexed sender, address indexed asset, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address _revenueReceiver,
    address _riskFundReceiver
  ) external initializer {
    require(_admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_manager != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_bot != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_pauser != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_revenueReceiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_riskFundReceiver != address(0), ErrorsLib.ZERO_ADDRESS);

    distributePercentage = DENOMINATOR / 2; // 50% to revenueReceiver
    revenueReceiver = _revenueReceiver;
    riskFundReceiver = _riskFundReceiver;

    __Pausable_init();
    __AccessControl_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);
    _grantRole(PAUSER, _pauser);
  }

  /**
   * @notice Distribute revenue to the revenueReceiver and the risk fund
   * @param assets the assets to distribute
   */
  function distribute(address[] memory assets) external onlyRole(BOT) whenNotPaused {
    require(assets.length > 0, ErrorsLib.ZERO_ASSETS);

    for (uint256 i = 0; i < assets.length; i++) {
      if (assets[i] == address(0)) {
        _distributeBnb();
        continue;
      }

      IERC20 asset = IERC20(assets[i]);
      uint256 revenueAmount = (asset.balanceOf(address(this)) * distributePercentage) / DENOMINATOR;
      uint256 riskFundAmount = asset.balanceOf(address(this)) - revenueAmount;

      if (revenueAmount > 0) {
        asset.safeTransfer(revenueReceiver, revenueAmount);
      }

      if (riskFundAmount > 0) {
        asset.safeTransfer(riskFundReceiver, riskFundAmount);
      }

      emit Distributed(assets[i], revenueReceiver, revenueAmount, riskFundReceiver, riskFundAmount);
    }
  }

  function _distributeBnb() private {
    uint256 balance = address(this).balance;
    if (balance > 0) {
      uint256 revenueAmount = (balance * distributePercentage) / DENOMINATOR;
      uint256 riskFundAmount = balance - revenueAmount;

      if (revenueAmount > 0) {
        (bool success, ) = revenueReceiver.call{ value: revenueAmount }("");
        require(success, "Bnb Transfer failed");
      }

      if (riskFundAmount > 0) {
        (bool success, ) = riskFundReceiver.call{ value: riskFundAmount }("");
        require(success, "Bnb Transfer failed");
      }

      emit Distributed(address(0), revenueReceiver, revenueAmount, riskFundReceiver, riskFundAmount);
    }
  }

  /// @dev Change the distribute percentage
  function setDistributePercentage(uint256 newDistributePercentage) external onlyRole(MANAGER) whenNotPaused {
    require(newDistributePercentage <= DENOMINATOR, "invalid distributePercentage");
    require(newDistributePercentage != distributePercentage, ErrorsLib.ALREADY_SET);

    distributePercentage = newDistributePercentage;
  }

  /// @dev Change the revenue receiver address
  function setRevenueReceiver(address newRevenueReceiver) external onlyRole(MANAGER) whenNotPaused {
    require(newRevenueReceiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(newRevenueReceiver != revenueReceiver, ErrorsLib.ALREADY_SET);

    revenueReceiver = newRevenueReceiver;
  }

  /// @dev Change the risk fund receiver address
  function setRiskFundReceiver(address newRiskFundReceiver) external onlyRole(MANAGER) whenNotPaused {
    require(newRiskFundReceiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(newRiskFundReceiver != riskFundReceiver, ErrorsLib.ALREADY_SET);

    riskFundReceiver = newRiskFundReceiver;
  }

  /// @dev Emergency withdraw assets from the contract
  /// @param assets the assets to withdraw
  function emergencyWithdraw(address[] memory assets) external onlyRole(MANAGER) {
    require(assets.length > 0, ErrorsLib.ZERO_ASSETS);

    for (uint256 i = 0; i < assets.length; i++) {
      if (assets[i] == address(0) && address(this).balance > 0) {
        (bool success, ) = msg.sender.call{ value: address(this).balance }("");
        require(success, "Transfer failed");
        emit EmergencyWithdrawn(msg.sender, assets[i], address(this).balance);
        continue;
      }

      IERC20 asset = IERC20(assets[i]);
      uint256 balance = asset.balanceOf(address(this));

      if (balance > 0) {
        asset.safeTransfer(msg.sender, balance);
        emit EmergencyWithdrawn(msg.sender, assets[i], balance);
      }
    }
  }

  /// @dev Pause the contract
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /// @dev Unpause the contract
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  receive() external payable {}
}

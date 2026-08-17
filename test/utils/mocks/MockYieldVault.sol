// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ERC20Mock } from "moolah-vault/mocks/ERC20Mock.sol";

/// @dev Minimal stand-in for MoolahVault. Reproduces the three behaviours the manager must survive:
///      a liquidity ceiling below the position value, a deposit whitelist on the receiver only, and
///      NAV that can move in both directions.
contract MockYieldVault is ERC4626 {
  using Math for uint256;
  /// @dev caps maxWithdraw, standing in for the real vault's withdraw-queue liquidity
  uint256 public liquidity = type(uint256).max;

  /// @dev makes withdraw deliver less than the assets it burned shares for — stands in for a vault
  ///      upgrade that changes withdraw semantics
  uint256 public withdrawShortfall;

  bool public whitelistEnabled;
  mapping(address => bool) public isWhiteList;

  constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Vault", "mVLT") {}

  function setLiquidity(uint256 _liquidity) external {
    liquidity = _liquidity;
  }

  function setWithdrawShortfall(uint256 amount) external {
    withdrawShortfall = amount;
  }

  /// @dev makes a share transfer a no-op that still returns true — stands in for a vault upgrade that
  ///      breaks transfers. SafeERC20 cannot catch that; emergencyWithdraw's balance check can.
  bool public transferNoop;

  function setTransferNoop(bool enabled) external {
    transferNoop = enabled;
  }

  function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
    if (transferNoop) return true;
    return super.transfer(to, value);
  }

  function setWhitelistEnabled(bool enabled) external {
    whitelistEnabled = enabled;
  }

  function setWhiteList(address account, bool enabled) external {
    isWhiteList[account] = enabled;
  }

  /// @dev raise NAV without minting shares — the mock's "yield accrued"
  function accrue(uint256 amount) external {
    ERC20Mock(asset()).mint(address(this), amount);
  }

  /// @dev lower NAV without burning shares — stands in for a loss or a lockBuffer dip (C1)
  function loss(uint256 amount) external {
    ERC20Mock(asset()).burn(address(this), amount);
  }

  function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
    uint256 supply = totalSupply();
    return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), rounding);
  }

  function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
    uint256 supply = totalSupply();
    return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, rounding);
  }

  function maxWithdraw(address owner) public view override returns (uint256) {
    return Math.min(super.maxWithdraw(owner), liquidity);
  }

  /// @dev the liquidity ceiling has to bind the redeem path too, or emergencyWithdraw would look
  ///      unbounded here. Skipped when uncapped, because converting type(uint256).max overflows.
  function maxRedeem(address owner) public view override returns (uint256) {
    if (liquidity == type(uint256).max) return super.maxRedeem(owner);
    return Math.min(super.maxRedeem(owner), convertToShares(liquidity));
  }

  /// @dev the real vault gates only the receiver of deposit/mint; withdraw/redeem/transfer are open
  function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    if (whitelistEnabled) require(isWhiteList[receiver], "NotWhiteList");
    super._deposit(caller, receiver, assets, shares);
  }

  /// @dev burns the full shares but delivers `assets - withdrawShortfall`
  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal override {
    uint256 delivered = assets > withdrawShortfall ? assets - withdrawShortfall : 0;
    super._withdraw(caller, receiver, owner, delivered, shares);
  }
}

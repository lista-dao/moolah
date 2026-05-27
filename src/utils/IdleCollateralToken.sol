// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IdleCollateralToken
/// @notice Non-transferable, zero-supply ERC20 used as the collateral token for Moolah idle markets.
contract IdleCollateralToken is IERC20, IERC20Metadata {
  error IdleCollateralNonTransferable();
  error IdleCollateralNonMintable();

  string private constant _NAME = "Moolah Idle Collateral";
  string private constant _SYMBOL = "Idle";
  uint8 private constant _DECIMALS = 18;

  function name() external pure returns (string memory) {
    return _NAME;
  }

  function symbol() external pure returns (string memory) {
    return _SYMBOL;
  }

  function decimals() external pure returns (uint8) {
    return _DECIMALS;
  }

  function totalSupply() external pure returns (uint256) {
    return 0;
  }

  function balanceOf(address) external pure returns (uint256) {
    return 0;
  }

  function allowance(address, address) external pure returns (uint256) {
    return 0;
  }

  function approve(address, uint256) external pure returns (bool) {
    revert IdleCollateralNonTransferable();
  }

  function transfer(address, uint256) external pure returns (bool) {
    revert IdleCollateralNonTransferable();
  }

  function transferFrom(address, address, uint256) external pure returns (bool) {
    revert IdleCollateralNonTransferable();
  }

  /// @dev Not part of IERC20. Kept as defense in depth: makes the no-mint invariant explicit at
  ///      the selector level for any custom integration that bypasses the IERC20 interface.
  function mint(address, uint256) external pure {
    revert IdleCollateralNonMintable();
  }
}

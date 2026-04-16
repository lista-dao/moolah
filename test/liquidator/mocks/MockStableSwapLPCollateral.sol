// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mock that exposes minter(), like the real StableSwapLPCollateral.
contract MockStableSwapLPCollateral is ERC20 {
  address public minter;

  constructor(string memory name, string memory symbol, address _minter) ERC20(name, symbol) {
    minter = _minter;
  }

  function setMinter(address _minter) external {
    minter = _minter;
  }
}

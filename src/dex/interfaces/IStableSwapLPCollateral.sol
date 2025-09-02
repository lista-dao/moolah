// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IStableSwapLPCollateral is IERC20 {
  function burn(address account, uint256 amount) external;

  function mint(address account, uint256 amount) external;
}

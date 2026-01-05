// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface ISlisBNBx is IERC20 {
  function burn(address account, uint256 amount) external;

  function mint(address account, uint256 amount) external;

  function decimals() external view returns (uint8);

  function addMinter(address minter) external;
}

interface ISlisBNBxModule {
  /// @notice Get user balance in BNB
  function getUserBalanceInBnb(address account) external pure returns (uint256);
}

interface ISlisBNBxMinter {
  function userModuleBalance(address account, address module) external view returns (uint256 userPart, uint256 feePart);

  /// @notice Rebalance user slisBNB tokens
  /// @param account The user address
  /// @return success True if rebalance is successful and new slisBNBx balance
  function rebalance(address account) external returns (bool, uint256);

  /// @notice Sync delegatee for user; can only be called by a module
  function syncDelegatee(address account, address newDelegatee) external;

  /// @notice Get delegatee for user
  function delegation(address account) external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface ICreditToken is IERC20 {
  function mint(address account, uint256 amount) external;

  function syncCreditScore(address _user, uint256 _creditScore, bytes32[] calldata _merkleProof) external;

  function setPendingMerkleRoot(bytes32 _pendingMerkleRoot) external;

  function acceptMerkleRoot() external;

  function debtOf(address account) external view returns (uint256);
}

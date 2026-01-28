// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Interface of the Credit Token contract
 */
interface ICreditToken is IERC20 {
  function syncCreditScore(address _user, uint256 _creditScore, bytes32[] calldata _merkleProof) external;

  function bulkSyncCreditScores(
    address[] calldata _users,
    uint256[] calldata _creditScores,
    bytes32[][] calldata _merkleProofs
  ) external;

  function setPendingMerkleRoot(bytes32 _pendingMerkleRoot) external;

  function acceptMerkleRoot() external;

  function revokePendingMerkleRoot() external;

  function debtOf(address account) external view returns (uint256);
}

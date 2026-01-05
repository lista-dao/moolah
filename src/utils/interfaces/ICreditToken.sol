// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface ICreditToken is IERC20 {
  function burn(address account, uint256 amount) external;

  function mint(address account, uint256 amount) external;

  function brokers(address broker) external view returns (bool);

  function lastSyncedScores(address account) external view returns (int256);

  function setMinter(address _minter, bool status) external;

  function syncCreditScore(address _user, uint256 _creditScore, bytes32[] calldata _merkleProof) external;

  function setPendingMerkleRoot(bytes32 _pendingMerkleRoot) external;

  function acceptMerkleRoot() external;
}

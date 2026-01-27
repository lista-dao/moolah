// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICreditToken, IERC20 } from "./interfaces/ICreditToken.sol";

/**
 * @title Credit Token
 * @author Lista DAO
 * @notice ERC20 token representing credit scores of users, with minting and burning based on verified credit scores via Merkle proofs.
 *         Tokens are 1:1 minted/burned according to the user's credit score.
 */
contract CreditToken is
  ERC20Upgradeable,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ICreditToken
{
  ///@dev Merkle tree root for credit score verification
  bytes32 public merkleRoot;

  /// @dev version id for the current merkle root; starts from 1 and increments by 1 for each new root
  uint256 public versionId;

  /// @dev Record of credit scores for each user
  mapping(address => CreditScore) public creditScores;

  struct CreditScore {
    uint256 id; // version id of the credit score
    uint256 score; // credit score value
  }

  /// @dev The accounted amount for each user: balance + deposits(open positions)
  /// @notice if userAmounts[user] > creditScores[user].score, which means user holds more tokens than their credit score allows, they have bad debt
  mapping(address => uint256) public userAmounts; // deposits, portfolio value

  /// @dev the next merkle root to be set
  bytes32 public pendingMerkleRoot;

  /// @dev last time pending merkle root was set
  uint256 public lastSetTime;

  /// @dev the waiting period before accepting the pending merkle root; 6 hours by default
  uint256 public waitingPeriod;

  // ------- Roles ------- //
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant TRANSFERER = keccak256("TRANSFERER");

  // ------- Events ------- //
  event ScoreSynced(
    address indexed _user,
    uint256 _newScore,
    uint256 _oldScore,
    uint256 _versionId,
    uint256 _lastVersionId
  );
  event SetPendingMerkleRoot(bytes32 indexed _pendingMerkleRoot, uint256 _setTime);
  event AcceptMerkleRoot(bytes32 indexed _merkleRoot, uint256 _acceptTime, uint256 _versionId);
  event WaitingPeriodUpdated(uint256 _newWaitingPeriod);

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address[] calldata _transferers, // only credit brokers and moolah can transfer
    string calldata _name,
    string calldata _symbol
  ) external initializer {
    require(_admin != address(0), "Zero address");
    require(_manager != address(0), "Zero address");
    require(_bot != address(0), "Zero address");

    __ERC20_init_unchained(_name, _symbol);
    __AccessControl_init_unchained();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);

    lastSetTime = type(uint256).max;
    waitingPeriod = 6 hours;

    for (uint256 i = 0; i < _transferers.length; i++) {
      _grantRole(TRANSFERER, _transferers[i]);
    }
    _setRoleAdmin(TRANSFERER, MANAGER);
  }

  /// @dev only Moolah can transfer
  /// @param to The address of the recipient.
  /// @param value The amount to be transferred.
  /// @return bool Returns true on success, false otherwise.
  function transfer(
    address to,
    uint256 value
  ) public override(IERC20, ERC20Upgradeable) onlyRole(TRANSFERER) returns (bool) {
    address owner = _msgSender();
    _transfer(owner, to, value);
    return true;
  }

  /// @dev only Moolah can call transferFrom
  function transferFrom(
    address from,
    address to,
    uint256 value
  ) public override(IERC20, ERC20Upgradeable) onlyRole(TRANSFERER) returns (bool) {
    address spender = _msgSender();
    _spendAllowance(from, spender, value);
    _transfer(from, to, value);
    return true;
  }

  function bulkSyncCreditScores(
    address[] calldata _users,
    uint256[] calldata _scores,
    bytes32[][] calldata _proofs
  ) external override {
    require(_users.length == _scores.length, "Mismatched inputs");
    require(_users.length == _proofs.length, "Mismatched inputs");

    for (uint256 i = 0; i < _users.length; i++) {
      syncCreditScore(_users[i], _scores[i], _proofs[i]);
    }
  }

  /**
   * @dev Sync credit score for a user; requires a valid Merkle proof.
   * @param _user The address of the user.
   * @param _score The latest credit score of the user.
   * @param _proof The Merkle proof for the user's latest credit score.
   */
  function syncCreditScore(address _user, uint256 _score, bytes32[] memory _proof) public override {
    require(merkleRoot != bytes32(0), "Invalid merkle root");

    CreditScore storage userScore = creditScores[_user];

    if (userScore.id != versionId || userScore.score != _score) {
      // verify merkle proof if score or version id changes
      bytes32 leaf = keccak256(abi.encode(block.chainid, address(this), _user, _score, versionId));
      require(MerkleProof.verify(_proof, merkleRoot, leaf), "Invalid proof");

      // update user's credit score and version id
      userScore.score = _score;
      userScore.id = versionId;
    }

    _syncCreditScore(_user, _score);

    emit ScoreSynced(_user, _score, userScore.score, versionId, userScore.id);
  }

  /**
   * @dev Internal function to sync credit score and mint/burn tokens accordingly.
   * @param _user The address of the user.
   * @param _newScore The new credit score of the user.
   */
  function _syncCreditScore(address _user, uint256 _newScore) private {
    uint256 debt = debtOf(_user);

    if (_newScore > userAmounts[_user]) {
      uint256 mintAmount = _newScore - userAmounts[_user];
      _mint(_user, mintAmount);
      userAmounts[_user] += mintAmount;
    } else if (_newScore < userAmounts[_user]) {
      uint256 burnAmount = userAmounts[_user] - _newScore;
      uint256 actualBurned = _safeBurn(_user, burnAmount);
      userAmounts[_user] -= actualBurned;
    }
  }

  /**
   * @dev Capped burn tokens from an account, ensuring not to exceed the account's balance.
   * @param _account The address of the account to burn tokens from.
   * @param _amount The expected amount to burn.
   */
  function _safeBurn(address _account, uint256 _amount) private returns (uint256) {
    uint256 balance = balanceOf(_account);
    uint256 burnAmount = _amount > balance ? balance : _amount;

    if (burnAmount > 0) {
      _burn(_account, burnAmount);
    }

    return burnAmount;
  }

  /**
   * @dev Get the debt of a user; if user's accounted amount exceeds their credit score, the excess is considered debt.
   *      Debt should be repaid before the user can borrow again.
   * @param _user The address of the user.
   * @return uint256 The debt amount of the user.
   */
  function debtOf(address _user) public view override returns (uint256) {
    uint256 score = creditScores[_user].score;
    return userAmounts[_user] > score ? userAmounts[_user] - score : 0;
  }

  ///////// Below are functions for merkle root management with timelock /////////

  /// @dev Set pending merkle root.
  /// @param _merkleRoot New merkle root to be set as pending
  function setPendingMerkleRoot(bytes32 _merkleRoot) external override onlyRole(BOT) whenNotPaused {
    require(
      _merkleRoot != bytes32(0) &&
        _merkleRoot != pendingMerkleRoot &&
        _merkleRoot != merkleRoot &&
        lastSetTime == type(uint256).max,
      "Invalid new merkle root"
    );

    pendingMerkleRoot = _merkleRoot;
    lastSetTime = block.timestamp;

    emit SetPendingMerkleRoot(_merkleRoot, lastSetTime);
  }

  /// @dev Accept the pending merkle root; pending merkle root can only be accepted after 1 day of setting
  function acceptMerkleRoot() external override onlyRole(BOT) whenNotPaused {
    require(pendingMerkleRoot != bytes32(0) && pendingMerkleRoot != merkleRoot, "Invalid pending merkle root");
    require(block.timestamp >= lastSetTime + waitingPeriod, "Not ready to accept");

    merkleRoot = pendingMerkleRoot;
    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;
    versionId += 1;

    emit AcceptMerkleRoot(merkleRoot, block.timestamp, versionId);
  }

  /// @dev Revoke the pending merkle root by Manager
  function revokePendingMerkleRoot() external override onlyRole(MANAGER) {
    require(pendingMerkleRoot != bytes32(0), "Pending merkle root is zero");

    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;

    emit SetPendingMerkleRoot(bytes32(0), lastSetTime);
  }

  /// @dev Change waiting period.
  /// @param _waitingPeriod Waiting period to be set
  function changeWaitingPeriod(uint256 _waitingPeriod) external onlyRole(MANAGER) whenNotPaused {
    require(_waitingPeriod >= 6 hours && _waitingPeriod != waitingPeriod, "Invalid waiting period");
    waitingPeriod = _waitingPeriod;

    emit WaitingPeriodUpdated(_waitingPeriod);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

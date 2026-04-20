// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

contract StableSwapLPCollateral is ERC20Upgradeable, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant TRANSFERER = keccak256("TRANSFERER");

  address public immutable MOOLAH;

  /// @notice The address of the minter. Should be the smart provider contract.
  address public minter;

  /// @notice Checks if the msg.sender is the minter address.
  modifier onlyMinter() {
    require(msg.sender == minter, "Not minter");
    _;
  }

  modifier onlyMoolahOrTransferer() {
    require(msg.sender == MOOLAH || hasRole(TRANSFERER, msg.sender), "Not moolah or transferer");
    _;
  }

  event SetMinter(address newMinter);
  event SetTransferer(address indexed account, bool enabled);

  constructor(address _moolah) {
    require(_moolah != address(0), "Zero address");

    _disableInitializers();
    MOOLAH = _moolah;
  }

  function initialize(
    address _admin,
    address _minter,
    string calldata _name,
    string calldata _symbol
  ) external initializer {
    require(_admin != address(0) && _minter != address(0), "Zero address");

    __ERC20_init(_name, _symbol);
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    minter = _minter;

    emit SetMinter(_minter);
  }

  function setMinter(address _newMinter) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_newMinter != address(0), "Zero address");
    require(_newMinter != minter, "Same minter");

    minter = _newMinter;
    emit SetMinter(_newMinter);
  }

  function setTransferer(address _account, bool _enabled) external onlyRole(MANAGER) {
    require(_account != address(0), "Zero address");

    if (_enabled) {
      _grantRole(TRANSFERER, _account);
    } else {
      _revokeRole(TRANSFERER, _account);
    }
    emit SetTransferer(_account, _enabled);
  }

  function mint(address _to, uint256 _amount) external onlyMinter {
    _mint(_to, _amount);
  }

  function burn(address _from, uint256 _amount) external onlyMinter {
    _burn(_from, _amount);
  }

  /// @dev only Moolah or TRANSFERER can transfer
  /// @param to The address of the recipient.
  /// @param value The amount to be transferred.
  /// @return bool Returns true on success, false otherwise.
  function transfer(address to, uint256 value) public override onlyMoolahOrTransferer returns (bool) {
    address owner = _msgSender();
    _transfer(owner, to, value);
    return true;
  }

  /// @dev only Moolah or TRANSFERER can call transferFrom
  function transferFrom(address from, address to, uint256 value) public override onlyMoolahOrTransferer returns (bool) {
    address spender = _msgSender();
    _spendAllowance(from, spender, value);
    _transfer(from, to, value);
    return true;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

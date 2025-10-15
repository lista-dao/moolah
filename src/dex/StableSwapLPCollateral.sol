// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

contract StableSwapLPCollateral is ERC20Upgradeable, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  address public immutable MOOLAH;

  /// @notice The address of the minter. Should be the smart provider contract.
  address public minter;

  /// @notice Checks if the msg.sender is the minter address.
  modifier onlyMinter() {
    require(msg.sender == minter, "Not minter");
    _;
  }

  /// @notice Checks if the msg.sender is the moolah address.
  modifier onlyMoolah() {
    require(msg.sender == MOOLAH, "Not moolah");
    _;
  }

  event SetMinter(address newMinter);

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

    string memory name = string.concat(_name, " - Collateral");
    string memory symbol = string.concat(_symbol, "-C");

    __ERC20_init(name, symbol);
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

  function mint(address _to, uint256 _amount) external onlyMinter {
    _mint(_to, _amount);
  }

  function burn(address _from, uint256 _amount) external onlyMinter {
    _burn(_from, _amount);
  }

  /// @dev only Moolah can transfer
  function transfer(address to, uint256 value) public override onlyMoolah returns (bool) {
    address owner = _msgSender();
    _transfer(owner, to, value);
    return true;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

contract StableSwapLP is ERC20Upgradeable, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  address public minter;

  /**
   * @notice Checks if the msg.sender is the minter address.
   */
  modifier onlyMinter() {
    require(msg.sender == minter, "Not minter");
    _;
  }

  event SetMinter(address newMinter);

  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin, address _minter, string memory name, string memory symbol) external initializer {
    require(_admin != address(0) && _minter != address(0), "Zero address");

    __ERC20_init(name, symbol);
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    minter = _minter;
    emit SetMinter(_minter);
  }

  function setMinter(address _newMinter) external onlyMinter {
    require(_newMinter != address(0), "Zero address");
    require(_newMinter != minter, "Same minter");

    minter = _newMinter;
    emit SetMinter(_newMinter);
  }

  function mint(address _to, uint256 _amount) external onlyMinter {
    _mint(_to, _amount);
  }

  function burnFrom(address _to, uint256 _amount) external onlyMinter {
    _burn(_to, _amount);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

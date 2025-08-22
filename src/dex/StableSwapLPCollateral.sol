// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract StableSwapLPCollateral is ERC20Upgradeable {
  address public minter;
  address public moolah;

  /// @notice Checks if the msg.sender is the minter address.
  modifier onlyMinter() {
    require(msg.sender == minter, "Not minter");
    _;
  }

  /// @notice Checks if the msg.sender is the moolah address.
  modifier onlyMoolah() {
    require(msg.sender == moolah, "Not moolah");
    _;
  }

  function initialize(address _moolah) external initializer {
    require(_moolah != address(0), "Zero address");

    __ERC20_init("Lista StableSwap LPs", "Stable-LP");
    minter = msg.sender;
    moolah = _moolah;
  }

  function setMinter(address _newMinter) external onlyMinter {
    minter = _newMinter;
  }

  function mint(address _to, uint256 _amount) external onlyMinter {
    _mint(_to, _amount);
  }

  function burn(address _to, uint256 _amount) external onlyMinter {
    _burn(_to, _amount);
  }

  /// @dev only Moolah can transfer
  function transfer(address to, uint256 value) public override onlyMoolah returns (bool) {
    address owner = _msgSender();
    _transfer(owner, to, value);
    return true;
  }
}

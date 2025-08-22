// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract StableSwapLP is ERC20Upgradeable {
  address public minter;

  /**
   * @notice Checks if the msg.sender is the minter address.
   */
  modifier onlyMinter() {
    require(msg.sender == minter, "Not minter");
    _;
  }

  function initialize() external initializer {
    __ERC20_init("Lista StableSwap LPs", "Stable-LP");
    minter = msg.sender;
  }

  function setMinter(address _newMinter) external onlyMinter {
    minter = _newMinter;
  }

  function mint(address _to, uint256 _amount) external onlyMinter {
    _mint(_to, _amount);
  }

  function burnFrom(address _to, uint256 _amount) external onlyMinter {
    _burn(_to, _amount);
  }
}

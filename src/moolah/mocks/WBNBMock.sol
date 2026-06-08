// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal WBNB mock: deposit() wraps native BNB, withdraw() unwraps to native.
contract WBNBMock is ERC20 {
  constructor() ERC20("Wrapped BNB", "WBNB") {}

  receive() external payable {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 wad) external {
    _burn(msg.sender, wad);
    (bool ok, ) = msg.sender.call{ value: wad }("");
    require(ok, "WBNB: transfer failed");
  }
}

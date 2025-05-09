// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ILpToken } from "moolah/interfaces/ILpToken.sol";

contract MockLpToken is ILpToken {
  uint256 public totalSupply;
  uint8 private _decimals;
  string public name;
  string public symbol;

  mapping(address account => uint256) public balanceOf;
  mapping(address account => mapping(address spender => uint256)) public allowance;

  function burn(address account, uint256 amount) external {
    require(amount > 0, "amount must be greater than 0");
    require(account != address(0), "account cannot be zero address");
    require(balanceOf[account] >= amount, "insufficient balance");

    balanceOf[account] -= amount;
    totalSupply -= amount;

    emit Transfer(account, address(0), amount);
  }

  function mint(address account, uint256 amount) external {
    require(amount > 0, "amount must be greater than 0");
    require(account != address(0), "account cannot be zero address");

    balanceOf[account] += amount;
    totalSupply += amount;

    emit Transfer(address(0), account, amount);
  }

  function approve(address spender, uint256 amount) public virtual returns (bool) {
    allowance[msg.sender][spender] = amount;

    emit Approval(msg.sender, spender, amount);

    return true;
  }

  function transfer(address to, uint256 amount) public virtual returns (bool) {
    require(balanceOf[msg.sender] >= amount, "insufficient balance");

    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;

    emit Transfer(msg.sender, to, amount);

    return true;
  }

  function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
    require(allowance[from][msg.sender] >= amount, "insufficient allowance");

    allowance[from][msg.sender] -= amount;

    require(balanceOf[from] >= amount, "insufficient balance");

    balanceOf[from] -= amount;
    balanceOf[to] += amount;

    emit Transfer(from, to, amount);

    return true;
  }

  function setDecimals(uint8 d) external {
    _decimals = d;
  }

  function decimals() external view returns (uint8) {
    if (_decimals != 0) return _decimals;
    return 18;
  }

  function setName(string memory _name) external {
    name = _name;
  }

  function setSymbol(string memory _symbol) external {
    symbol = _symbol;
  }

}

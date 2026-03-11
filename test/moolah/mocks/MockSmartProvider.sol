// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract MockSmartProvider {
  address public TOKEN;
  address[] public tokens;

  mapping(address => uint256) public price;

  constructor(address _token) {
    TOKEN = _token;
  }

  function peek(address asset) external view returns (uint256) {
    return price[asset];
  }

  function setPrice(address asset, uint256 newPrice) external {
    price[asset] = newPrice;
  }

  function token(uint256 i) external view returns (address) {
    return tokens[i];
  }

  function addToken(address token) external {
    tokens.push(token);
  }
}

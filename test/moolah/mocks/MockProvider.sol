// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract MockProvider {
  address public TOKEN;

  constructor(address _token) {
    TOKEN = _token;
  }
}

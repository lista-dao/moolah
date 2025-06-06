// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IStakeManager } from "../../../src/provider/interfaces/IStakeManager.sol";

contract MockStakeManager is IStakeManager {
  uint256 public exchangeRate;

  function setExchangeRate(uint256 _exchangeRate) external {
    exchangeRate = _exchangeRate;
  }

  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256) {
    return (_amount * exchangeRate) / 1e18;
  }

  function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256) {
    return (_amountInSlisBnb * 1e18) / exchangeRate;
  }
}

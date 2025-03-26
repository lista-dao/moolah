//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

interface IStakeManager {
  function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

  function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "moolah/interfaces/IMoolah.sol";

interface IProvider {
  function liquidate(Id id, address borrower) external;

  function TOKEN() external view returns (address);
}

interface ISmartProvider is IProvider {
  function liquidate(
    Id id,
    address payable liquidator,
    uint256 seizedAssets,
    bytes calldata payload // abi encoded data of minAmounts
  ) external;
}

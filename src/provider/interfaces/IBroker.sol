// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "moolah/interfaces/IMoolah.sol";

/// @dev Broker interface
interface IBroker {
  function LOAN_TOKEN() external view returns (address);
  function COLLATERAL_TOKEN() external view returns (address);
}

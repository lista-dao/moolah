// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import "./MoolahHarness.sol";

contract MoolahInternalAccess is MoolahHarness {
  function update(Id id, uint256 timestamp) external {
    market[id].lastUpdate = uint128(timestamp);
  }

  function increaseInterest(Id id, uint128 interest) external {
    market[id].totalBorrowAssets += interest;
    market[id].totalSupplyAssets += interest;
  }
}

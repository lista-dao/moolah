// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams } from "../../moolah/interfaces/IMoolah.sol";

/// @title IPositionManager
/// @notice Interface for migrating a variable-rate borrow position to a fixed-term position.
interface IPositionManager {
  /// @notice Migrate a portion of a variable-rate position in `outMarket` to a fixed-term position in `inMarket`.
  /// @dev Caller must have pre-authorized this contract in Moolah via `MOOLAH.setAuthorization(positionManager, true)`.
  ///      The migration is executed atomically using a flash loan.
  ///      Exactly one of `borrowAmount` or `borrowShares` must be non-zero.
  /// @param outMarket The variable-rate market to migrate from
  /// @param inMarket  The fixed-term market to migrate to (must have a LendingBroker registered)
  /// @param collateralAmount Amount of collateral to move from outMarket to inMarket
  /// @param borrowAmount Amount of borrowed debt to migrate (partial migration, set 0 if using borrowShares)
  /// @param borrowShares Borrow shares to repay for exact full migration (set 0 if using borrowAmount)
  /// @param termId The fixed-term product ID in the inMarket's LendingBroker
  function migrateCommonMarketToFixedTermMarket(
    MarketParams calldata outMarket,
    MarketParams calldata inMarket,
    uint256 collateralAmount,
    uint256 borrowAmount,
    uint256 borrowShares,
    uint256 termId
  ) external;
}

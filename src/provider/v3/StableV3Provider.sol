// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { V3Provider } from "./V3Provider.sol";

/**
 * @title StableV3Provider
 * @author Lista DAO
 * @notice Stable-pair V3 LP vault: the base {V3Provider} plus the BOT-gated rebalance forwarder.
 */
contract StableV3Provider is V3Provider {
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _moolah, address _adapter) V3Provider(_moolah, _adapter) {}

  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _resilientOracle,
    address _accountingAsset,
    string calldata _name,
    string calldata _symbol
  ) external initializer {
    __V3Provider_init(_admin, _manager, _bot, _resilientOracle, _accountingAsset, _name, _symbol);
  }

  /// @notice BOT-gated recenter + inventory conversion; forwards to the adapter.
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint160 targetSqrtPriceX96,
    uint256 expectedCenterRate,
    uint256 deadline,
    bytes calldata swapData
  ) external onlyRole(BOT) nonReentrant {
    _guardedRebalance(minAmount0, minAmount1, minLiquidity, targetSqrtPriceX96, expectedCenterRate, deadline, swapData);
  }
}

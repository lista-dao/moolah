// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { V3Provider } from "./V3Provider.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";

/**
 * @title WstETHV3Provider
 * @author Lista DAO
 * @notice wstETH/WETH V3 LP vault (Ethereum). A lean {V3Provider}: no reward-token mirroring and no
 *         per-user deposit tracking (there is no slisBNBx analogue) — it inherits the base deposit /
 *         withdraw / redeem flow unchanged and only adds the BOT-gated rebalance forwarder.
 */
contract WstETHV3Provider is V3Provider {
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

  /// @notice Recenter the position and convert inventory to the optimal ratio. BOT-gated; forwards to
  ///         the adapter (which is `onlyProvider`). `swapData` is built by the BOT backend and encodes
  ///         (swapPair, sellToken0, amountIn, amountOutMin, innerSwapData) for the rebalance swap.
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint256 deadline,
    bytes calldata swapData
  ) external onlyRole(BOT) nonReentrant {
    IV3DexAdapter(ADAPTER).rebalance(minAmount0, minAmount1, minLiquidity, deadline, swapData);
  }
}

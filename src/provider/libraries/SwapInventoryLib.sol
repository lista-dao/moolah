// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IWBNB } from "../interfaces/IWBNB.sol";

/**
 * @title SwapInventoryLib
 * @author Lista DAO
 * @notice DEX-agnostic inventory-conversion swap shared by the V3 LP adapters during rebalance. Mirrors
 *         {Liquidator}'s aggregator pattern: the (BOT) backend builds `swapData` for ANY whitelisted venue
 *         (1inch / 0x / Uniswap / a StakeManager instant-redeem / …); the adapter just forwards it via a
 *         low-level `swapPair.call(swapData)` and enforces the result with MEASURED balance deltas —
 *         `spent <= amountIn` and `received >= amountOutMin`. No on-chain routing or price math.
 *
 *         A venue may settle the wrapped-native leg as the NATIVE coin instead of the ERC20 (e.g. a Lista
 *         StakeManager `instantWithdraw` that pays out BNB). When the output leg is the wrapped-native
 *         token, any native delivered by the call is wrapped back into it before `received` is measured —
 *         so instant-redeem venues are supported without any special-casing in the adapter.
 *
 * @dev Invoked via DELEGATECALL, so `address(this)` is the adapter: token custody, allowances and any
 *      native received resolve to the adapter, and the swap output must land in the adapter (otherwise
 *      `received` is 0 and the swap reverts). The adapter whitelists `swapPair`; `amountIn`/`amountOutMin`/
 *      `swapData` come from the backend. `amountIn` is capped to the available balance, and the allowance
 *      to `swapPair` is set to `amountIn` then reset to 0 after the call.
 */
library SwapInventoryLib {
  using SafeERC20 for IERC20;

  error SwapFailed();
  error ExceedAmountIn();
  error InsufficientOutput();

  /// @notice Execute one backend-built swap. `sellToken0` ⇒ sell token0 for token1, else token1 for
  ///         token0. `wrappedNative` is the adapter's wrapped-native token: native delivered by the
  ///         venue for the wrapped-native output leg is wrapped into it. Returns (total0, total1)
  ///         adjusted by the MEASURED spent/received deltas.
  function swap(
    address swapPair,
    address token0,
    address token1,
    bool sellToken0,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes memory swapData,
    uint256 total0,
    uint256 total1,
    address wrappedNative
  ) external returns (uint256, uint256) {
    if (amountIn == 0) return (total0, total1);

    address tokenIn = sellToken0 ? token0 : token1;
    address tokenOut = sellToken0 ? token1 : token0;

    uint256 avail = sellToken0 ? total0 : total1;
    if (amountIn > avail) amountIn = avail; // never spend more than the position holds
    if (amountIn == 0) return (total0, total1);

    uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
    uint256 beforeOut = IERC20(tokenOut).balanceOf(address(this));
    uint256 beforeNative = address(this).balance;

    IERC20(tokenIn).forceApprove(swapPair, amountIn);
    (bool ok, ) = swapPair.call(swapData);
    if (!ok) revert SwapFailed();
    IERC20(tokenIn).forceApprove(swapPair, 0); // clear any residual allowance

    // A venue may settle the wrapped-native output leg as the native coin (e.g. StakeManager
    // instantWithdraw → BNB). Wrap whatever native THIS call delivered so the tokenOut delta captures it.
    if (tokenOut == wrappedNative) {
      uint256 cur = address(this).balance;
      uint256 nativeIn = cur > beforeNative ? cur - beforeNative : 0;
      if (nativeIn > 0) IWBNB(wrappedNative).deposit{ value: nativeIn }();
    }

    uint256 spent = beforeIn - IERC20(tokenIn).balanceOf(address(this));
    uint256 received = IERC20(tokenOut).balanceOf(address(this)) - beforeOut;
    if (spent > amountIn) revert ExceedAmountIn();
    if (received < amountOutMin) revert InsufficientOutput();

    if (sellToken0) {
      total0 -= spent;
      total1 += received;
    } else {
      total1 -= spent;
      total0 += received;
    }
    return (total0, total1);
  }
}

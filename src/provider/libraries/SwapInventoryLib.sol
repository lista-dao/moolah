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
 *         (1inch / 0x / Uniswap / a StakeManager instant-redeem or stake / …); the adapter just forwards
 *         it via a low-level call and enforces the result with MEASURED balance deltas — `spent <= amountIn`
 *         and `received >= amountOutMin`. No on-chain routing or price math.
 *
 *         The wrapped-native leg may be settled in the NATIVE coin on either side, so the venue's calling
 *         convention is symmetric:
 *           - native OUT (e.g. instantWithdraw → BNB): any native the call delivers is wrapped back into
 *             the wrapped-native ERC20 before `received` is measured;
 *           - native IN  (e.g. StakeManager.deposit{value}): set `nativeIn` and the wrapped-native input is
 *             unwrapped to the native coin and forwarded as `msg.value` (instead of an ERC20 allowance).
 *         Any native delivered is ALWAYS wrapped (never stranded); if neither leg is the wrapped-native it
 *         reverts {UnexpectedNative}.
 *
 * @dev Invoked via DELEGATECALL, so `address(this)` is the adapter: token custody, allowances and any
 *      native received resolve to the adapter, and the swap output must land in the adapter (otherwise
 *      `received` is 0 and the swap reverts). The adapter whitelists `swapPair`; `amountIn`/`amountOutMin`/
 *      `nativeIn`/`swapData` come from the backend. `amountIn` is capped to the available balance; the ERC-20
 *      allowance to `swapPair` is set to `amountIn` then reset to 0 after the call.
 */
library SwapInventoryLib {
  using SafeERC20 for IERC20;

  error SwapFailed();
  error ExceedAmountIn();
  error InsufficientOutput();
  error UnexpectedNative();
  error InsufficientInventory();

  /// @notice Execute one backend-built swap. `sellToken0` ⇒ sell token0 for token1, else token1 for
  ///         token0. `nativeIn` ⇒ the venue takes the native coin for the wrapped-native input leg
  ///         (unwrap + call{value}); otherwise the input is an ERC-20 (approve + call). `wrappedNative` is
  ///         the adapter's wrapped-native token. Returns (total0, total1) adjusted by MEASURED deltas.
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
    address wrappedNative,
    bool nativeIn
  ) external returns (uint256, uint256) {
    if (amountIn == 0) return (total0, total1);

    address tokenIn = sellToken0 ? token0 : token1;
    address tokenOut = sellToken0 ? token1 : token0;

    uint256 avail = sellToken0 ? total0 : total1;
    if (avail == 0) return (total0, total1); // nothing to sell

    // Stale swapData (requested > held): fail fast. Capping would desync the venue allowance from
    // swapData and could underflow the totals. Now amountIn <= avail, so the allowance matches the pull.
    if (amountIn > avail) revert InsufficientInventory();

    uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
    uint256 beforeOut = IERC20(tokenOut).balanceOf(address(this));
    uint256 beforeNative = address(this).balance;

    if (nativeIn) {
      // Native-input venue (e.g. StakeManager.deposit{value}): only the wrapped-native leg can be paid
      // as the native coin. Unwrap the wrapped-native ERC-20 and forward it as msg.value.
      if (tokenIn != wrappedNative) revert UnexpectedNative();
      IWBNB(wrappedNative).withdraw(amountIn);
      (bool ok, ) = swapPair.call{ value: amountIn }(swapData);
      if (!ok) revert SwapFailed();
    } else {
      IERC20(tokenIn).forceApprove(swapPair, amountIn);
      (bool ok, ) = swapPair.call(swapData);
      if (!ok) revert SwapFailed();
      IERC20(tokenIn).forceApprove(swapPair, 0); // clear any residual allowance
    }

    // Wrap any native this call delivered — a native-out venue's proceeds (instantWithdraw → BNB) or a
    // native-in venue's unspent refund — back into the wrapped-native ERC-20, so it is booked into the
    // totals via the spent/received deltas and never stranded. Only a wrapped-native leg can legitimately
    // deliver native; wrap the delta ONLY when either leg is the wrapped-native token. If NEITHER leg is
    // (an ERC-20↔ERC-20 swap on a future non-native pair), any native that appears is an unsolicited
    // donation the venue forwarded (e.g. a router that sweeps its native balance; an attacker can seed it
    // with 1 wei) — it is not part of this swap's accounting, so leave it untouched rather than reverting
    // and bricking the rebalance.
    if ((tokenIn == wrappedNative || tokenOut == wrappedNative) && address(this).balance > beforeNative) {
      IWBNB(wrappedNative).deposit{ value: address(this).balance - beforeNative }();
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

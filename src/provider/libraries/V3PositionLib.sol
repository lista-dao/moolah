// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { INonfungiblePositionManager } from "../interfaces/INonfungiblePositionManager.sol";

/**
 * @title V3PositionLib
 * @author Lista DAO
 * @notice External library holding the (user-invisible) NonfungiblePositionManager interaction
 *         primitives — mint / increaseLiquidity / decreaseLiquidity / collect / burn — that
 *         {V3Provider} repeats across deposit, withdraw, compound and rebalance.
 *
 *         These functions are `external`, so the library is deployed once and linked into the
 *         provider; the heavy NPM struct-encoding bytecode lives here instead of being duplicated
 *         in every provider call site, which keeps the provider implementation under EIP-170.
 *
 * @dev    The library is invoked via DELEGATECALL, so inside every function `address(this)` is the
 *         provider: token custody, allowances and the collect `recipient` all resolve to the
 *         provider, exactly as the inline code did. The provider's immutables (NPM address, token
 *         addresses, fee) are not readable from library code, so they are passed in as arguments.
 *         `recipient` is always `address(this)` and `deadline` always `block.timestamp`, matching
 *         the previous inline behaviour.
 */
library V3PositionLib {
  using SafeERC20 for IERC20;

  /// @dev Approve `npm` for both tokens and mint a fresh position to the provider.
  function mint(
    INonfungiblePositionManager npm,
    address token0,
    address token1,
    uint24 fee,
    int24 tickLower,
    int24 tickUpper,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
    IERC20(token0).safeIncreaseAllowance(address(npm), amount0Desired);
    IERC20(token1).safeIncreaseAllowance(address(npm), amount1Desired);
    return
      npm.mint(
        INonfungiblePositionManager.MintParams({
          token0: token0,
          token1: token1,
          fee: fee,
          tickLower: tickLower,
          tickUpper: tickUpper,
          amount0Desired: amount0Desired,
          amount1Desired: amount1Desired,
          amount0Min: amount0Min,
          amount1Min: amount1Min,
          recipient: address(this),
          deadline: block.timestamp
        })
      );
  }

  /// @dev Approve `npm` for both tokens and add liquidity to an existing position.
  function increaseLiquidity(
    INonfungiblePositionManager npm,
    address token0,
    address token1,
    uint256 tokenId,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    IERC20(token0).safeIncreaseAllowance(address(npm), amount0Desired);
    IERC20(token1).safeIncreaseAllowance(address(npm), amount1Desired);
    return
      npm.increaseLiquidity(
        INonfungiblePositionManager.IncreaseLiquidityParams({
          tokenId: tokenId,
          amount0Desired: amount0Desired,
          amount1Desired: amount1Desired,
          amount0Min: amount0Min,
          amount1Min: amount1Min,
          deadline: block.timestamp
        })
      );
  }

  /// @dev Remove `liquidity` from the position (tokens are accounted to tokensOwed; collect separately).
  function decreaseLiquidity(
    INonfungiblePositionManager npm,
    uint256 tokenId,
    uint128 liquidity,
    uint256 amount0Min,
    uint256 amount1Min
  ) external {
    npm.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: liquidity,
        amount0Min: amount0Min,
        amount1Min: amount1Min,
        deadline: block.timestamp
      })
    );
  }

  /// @dev Collect all owed tokens (fees + decreased liquidity) to the provider.
  function collectAll(
    INonfungiblePositionManager npm,
    uint256 tokenId
  ) external returns (uint256 amount0, uint256 amount1) {
    return
      npm.collect(
        INonfungiblePositionManager.CollectParams({
          tokenId: tokenId,
          recipient: address(this),
          amount0Max: type(uint128).max,
          amount1Max: type(uint128).max
        })
      );
  }

  /// @dev Burn an empty position NFT.
  function burn(INonfungiblePositionManager npm, uint256 tokenId) external {
    npm.burn(tokenId);
  }
}

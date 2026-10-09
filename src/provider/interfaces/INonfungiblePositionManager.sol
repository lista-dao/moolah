// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title Minimal Lista V3 / Uniswap V3 NonfungiblePositionManager interface
/// @notice Self-contained subset consumed by {V3Provider}. The full interface in the
///         lista-v3 dependency (lib/lista-v3) is Solidity 0.7.6 and inherits OpenZeppelin
///         ERC721 upgradeable interfaces whose paths/names differ from this repo's OZ v5.2,
///         so it cannot be imported into a 0.8.34 contract. Only the methods V3Provider
///         actually calls are declared here.
interface INonfungiblePositionManager {
  /// @notice The address of the factory that created the position manager's pools.
  function factory() external view returns (address);

  /// @notice Returns the position information associated with a given token ID.
  function positions(
    uint256 tokenId
  )
    external
    view
    returns (
      uint96 nonce,
      address operator,
      address token0,
      address token1,
      uint24 fee,
      int24 tickLower,
      int24 tickUpper,
      uint128 liquidity,
      uint256 feeGrowthInside0LastX128,
      uint256 feeGrowthInside1LastX128,
      uint128 tokensOwed0,
      uint128 tokensOwed1
    );

  struct MintParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
  }

  /// @notice Creates a new position wrapped in a NFT.
  function mint(
    MintParams calldata params
  ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

  struct IncreaseLiquidityParams {
    uint256 tokenId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  /// @notice Increases the amount of liquidity in a position, with tokens paid by `msg.sender`.
  function increaseLiquidity(
    IncreaseLiquidityParams calldata params
  ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

  struct DecreaseLiquidityParams {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  /// @notice Decreases the amount of liquidity in a position and accounts it to the position.
  function decreaseLiquidity(
    DecreaseLiquidityParams calldata params
  ) external payable returns (uint256 amount0, uint256 amount1);

  struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
  }

  /// @notice Collects up to a maximum amount of fees owed to a specific position to the recipient.
  function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

  /// @notice Burns a token ID, which deletes it from the NFT contract. The token must have 0 liquidity
  ///         and all tokens must be collected first.
  function burn(uint256 tokenId) external payable;
}

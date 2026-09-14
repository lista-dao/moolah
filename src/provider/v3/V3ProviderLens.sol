// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IOracle } from "moolah/interfaces/IOracle.sol";

import { IV3Provider } from "../interfaces/IV3Provider.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";
import { V3ProviderLib } from "../libraries/V3ProviderLib.sol";

/**
 * @title V3ProviderLens
 * @author Lista DAO
 * @notice Read-only companion to a {V3Provider} vault: the composition and preview quotes that only
 *         front-ends and bots call. Nothing in `src/` reads them, so they live here instead of in the
 *         provider implementation, which is at the EIP-170 limit.
 *
 * @dev Stateless and non-upgradeable — redeploy to change it. Deposit share pricing is NOT duplicated
 *      here: `previewDepositShares`/`previewDepositAmounts` forward to `V3Provider.quoteDeposit`, the
 *      same `_quoteDeposit` `deposit()` uses, so a preview cannot drift from the mint. Only the
 *      first-deposit (supply == 0) branch is re-derived, mirroring the provider's opening mint.
 */
contract V3ProviderLens {
  error ZeroAddress();
  error ZeroAmounts();
  /// @dev Raised from {V3ProviderLib} on a dead feed; declared here so it stays in this ABI (a custom
  ///      error selector comes from its signature alone).
  error OracleZero();
  error ProviderAdapterMismatch();

  /// @dev The vault this lens previews.
  IV3Provider public immutable PROVIDER;

  /// @dev The vault's DEX adapter (NFT custodian + position/composition math).
  IV3DexAdapter public immutable ADAPTER;

  /// @dev Pool tokens and their decimals, mirrored from the adapter exactly as the provider does.
  address public immutable TOKEN0;
  address public immutable TOKEN1;
  uint8 public immutable DECIMALS0;
  uint8 public immutable DECIMALS1;

  uint256 private constant WAD = 1e18;

  constructor(address _provider, address _adapter) {
    if (_provider == address(0) || _adapter == address(0)) revert ZeroAddress();
    if (IV3Provider(_provider).ADAPTER() != _adapter) revert ProviderAdapterMismatch();
    PROVIDER = IV3Provider(_provider);
    ADAPTER = IV3DexAdapter(_adapter);
    TOKEN0 = IV3DexAdapter(_adapter).TOKEN0();
    TOKEN1 = IV3DexAdapter(_adapter).TOKEN1();
    DECIMALS0 = IV3DexAdapter(_adapter).DECIMALS0();
    DECIMALS1 = IV3DexAdapter(_adapter).DECIMALS1();
  }

  /* ───────────────────────── view functions ───────────────────────── */

  /// @notice Total token0/token1 backing the vault at the current pool spot (display/bots).
  function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
    return ADAPTER.positionAmountsAt(ADAPTER.spotSqrtPriceX96());
  }

  /// @notice The managed position's token composition valued at the FAIR (manipulation-resistant)
  ///         price, inclusive of idle inventory and collected fees. This is the ratio a subsequent
  ///         deposit binds to; front-ends should size the two deposit legs in this ratio to minimise
  ///         the refund. Returns (0, 0) before the first deposit (no position yet) — use
  ///         previewDepositAmounts for that case.
  function getFairComposition() public view returns (uint256 total0, uint256 total1) {
    return ADAPTER.positionAmountsAt(ADAPTER.fairSqrtPriceX96());
  }

  /// @notice Simulate a redemption of `shares` at the current pool price (for tight minAmount0/1).
  function previewRedeemUnderlying(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
    return ADAPTER.previewRemoveLiquidity(shares, IERC4626(address(PROVIDER)).totalSupply());
  }

  /// @notice Preview the token amounts a deposit would consume.
  /// @dev For the first deposit (totalSupply == 0) this previews the pool mint (liquidity + amounts at
  ///      spot). For subsequent deposits it forwards to the vault's own deposit quote, so the amounts
  ///      are exactly what deposit() consumes, and `liquidity` is 0 since the deposit is parked as idle
  ///      rather than minted.
  function previewDepositAmounts(
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    if (IERC4626(address(PROVIDER)).totalSupply() == 0) {
      return ADAPTER.previewAddLiquidity(amount0Desired, amount1Desired);
    }
    (, amount0, amount1) = PROVIDER.quoteDeposit(amount0Desired, amount1Desired);
  }

  /// @notice Preview the shares a deposit would mint — the exact min(fair, spot) credit deposit() uses.
  ///         Frontends size `minShares` off this (× a slippage tolerance). First deposit (supply == 0)
  ///         previews the oracle-valued opening mint.
  /// @param amount0Desired token0 offered by the depositor.
  /// @param amount1Desired token1 offered by the depositor.
  /// @return shares shares deposit() would mint for these amounts.
  function previewDepositShares(uint256 amount0Desired, uint256 amount1Desired) external view returns (uint256 shares) {
    if (IERC4626(address(PROVIDER)).totalSupply() > 0) {
      (shares, , ) = PROVIDER.quoteDeposit(amount0Desired, amount1Desired);
      return shares;
    }
    (uint128 liquidity, , ) = ADAPTER.previewAddLiquidity(amount0Desired, amount1Desired);
    (uint256 added0, uint256 added1) = ADAPTER.amountsForLiquidity(liquidity, ADAPTER.fairSqrtPriceX96());
    uint256 assetPrice = IOracle(PROVIDER.resilientOracle()).peek(IERC4626(address(PROVIDER)).asset());
    if (assetPrice > 0)
      shares = (_amountsValueUsd(added0, added1) * (10 ** uint256(PROVIDER.accountingAssetDecimals()))) / assetPrice;
  }

  /// @notice Given a desired token0 amount, the token1 amount that pairs with it at the current fair
  ///         composition ratio, so a subsequent deposit consumes both legs fully (minimal refund).
  /// @dev    amount1 = amount0 * T1 / T0, where (T0, T1) = getFairComposition(). Reverts once fair has
  ///         drifted past tickUpper (no token0 leg); deposits are then closed in every shape until the
  ///         BOT recenters. Symmetric below tickLower. First deposit: use previewDepositAmounts.
  function previewDepositForToken0(uint256 amount0) external view returns (uint256 amount1) {
    (uint256 t0, uint256 t1) = getFairComposition();
    if (t0 == 0) revert ZeroAmounts();
    amount1 = (amount0 * t1) / t0;
  }

  /// @notice Mirror of previewDepositForToken0: the token0 amount that pairs with a desired token1
  ///         amount at the current fair composition ratio (amount0 = amount1 * T0 / T1).
  function previewDepositForToken1(uint256 amount1) external view returns (uint256 amount0) {
    (uint256 t0, uint256 t1) = getFairComposition();
    if (t1 == 0) revert ZeroAmounts();
    amount0 = (amount1 * t0) / t1;
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  /// @dev Value token0/token1 amounts as 8-decimal USD, through the very same {V3ProviderLib} the vault
  ///      values its position with — not a copy of it — so the first-deposit preview cannot drift from
  ///      the opening mint. Only that branch (no share supply to quote against) needs it.
  /// @dev The oracle is read from the vault on every call rather than cached: `resilientOracle` is a
  ///      mutable variable there, not an immutable.
  function _amountsValueUsd(uint256 amount0, uint256 amount1) private view returns (uint256) {
    return
      V3ProviderLib.amountsValueUsd(
        V3ProviderLib.Ctx(address(ADAPTER), PROVIDER.resilientOracle(), TOKEN0, TOKEN1, DECIMALS0, DECIMALS1),
        amount0,
        amount1
      );
  }
}

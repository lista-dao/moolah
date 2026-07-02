// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { V3DexAdapter } from "./V3DexAdapter.sol";
import { IStakeManager } from "../interfaces/IStakeManager.sol";
import { ISlisBNBV3DexAdapter } from "../interfaces/ISlisBNBV3DexAdapter.sol";

/**
 * @title SlisBNBV3DexAdapter
 * @author Lista DAO
 * @notice slisBNB/BNB specialization of {V3DexAdapter}. The base carries the rate-implied fair price,
 *         ±1% rate-centered tick range, the rebalance skeleton and the DEX-agnostic, backend-built swap
 *         conversion + swap-pair whitelist (shared with the wstETH/wbETH families). This subclass supplies
 *         only the slisBNB-specific hook:
 *           - _lstNativeRate(): StakeManager slisBNB↔BNB rate (not pool spot/TWAP).
 *         The rebalance inventory conversion is a backend-built swap against a whitelisted venue — the
 *         StakeManager instant-redeem is just one possible such venue and is no longer special-cased on
 *         chain. `receive()` is inherited: it accepts native BNB only from the WBNB unwrap.
 */
contract SlisBNBV3DexAdapter is V3DexAdapter, ISlisBNBV3DexAdapter {
  /* ─────────────────────────── constants ──────────────────────────── */

  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  IStakeManager public constant STAKE_MANAGER = IStakeManager(0x1adB950d8bB3dA4bE104211D5AB038628e477fE6);

  /// @dev BSC wrapped native token (forwarded to the base as WRAPPED_NATIVE).
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  /* ───────────────────────────── errors ───────────────────────────── */

  error NotSlisBnbWbnbPair();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _positionManager,
    address _token0,
    address _token1,
    uint24 _fee,
    uint32 _twapPeriod
  ) V3DexAdapter(_positionManager, _token0, _token1, _fee, _twapPeriod, WBNB) {
    // slisBNB/BNB-ONLY: the rate-implied fair price and ±1% tick centering assume token0 == slisBNB and
    // token1 == WBNB. The base already enforces token0 < token1, and slisBNB < WBNB, so this is the only
    // valid ordering — reject anything else.
    if (!(_token0 == SLISBNB && _token1 == WBNB)) revert NotSlisBnbWbnbPair();
  }

  /**
   * @param _admin   Default admin (upgrade / roles).
   * @param _manager Manager role (sets centerRateThresholdBps + the swap-pair whitelist).
   */
  function initialize(address _admin, address _manager) external initializer {
    uint256 initialCenterRate = _lstNativeRate();
    (int24 initialTickLower, int24 initialTickUpper) = _initialTickRange(initialCenterRate);
    __V3DexAdapter_init(_admin, _manager, initialTickLower, initialTickUpper);
    lastCenterRate = initialCenterRate;
    centerRateThresholdBps = INITIAL_RANGE_BPS;
  }

  /* ───────────────────────── hook overrides ───────────────────────── */

  /// @dev slisBNB↔BNB rate from the StakeManager (1e18). 0 for any non-slisBNB/WBNB pair → base TWAP.
  function _lstNativeRate() internal view override returns (uint256) {
    return _isSlisBnbWbnbPool() ? _poolPriceRate() : 0;
  }

  /* ─────────────────────────── internals ──────────────────────────── */

  function _isSlisBnbWbnbPool() internal view returns (bool) {
    return (TOKEN0 == SLISBNB && TOKEN1 == WBNB) || (TOKEN0 == WBNB && TOKEN1 == SLISBNB);
  }

  function _poolPriceRate() internal view returns (uint256) {
    return TOKEN0 == SLISBNB ? STAKE_MANAGER.convertSnBnbToBnb(1e18) : STAKE_MANAGER.convertBnbToSnBnb(1e18);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";
import { IV3Provider } from "../interfaces/IV3Provider.sol";
import { IV3ProviderOracle } from "../interfaces/IV3ProviderOracle.sol";

/**
 * @title V3ProviderOracle
 * @author Lista DAO
 * @notice Standalone IOracle for a V3 LP vLP share token (Moolah `market.oracle` points here). Prices
 *         the share off the DEX adapter's manipulation-resistant FAIR composition view (staticcall, no
 *         double-hop through the vault) — that fair price is exchange-rate-implied (slisBNB) or pool
 *         TWAP clamped to the rate (wstETH/wbETH), never raw pool spot — then values each leg via the
 *         resilient oracle and applies a conservative haircut. The resilient oracle prices the LST leg
 *         RATE-DERIVED (peek(LST) == peek(underlying) × exchangeRate / 1e18), so the leg valuation is
 *         consistent with the rate-anchored composition — see peek()'s AUDIT NOTE. Chain/pair-agnostic:
 *         the pair is taken from the constructor and validated against the adapter.
 *
 * @dev finding D — when supply > 0, peek(share) reverts on a zero leg price or zero total value so
 *      Moolah never prices collateral off a broken feed; supply == 0 returns 0 (pre-market).
 */
contract V3ProviderOracle is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IV3ProviderOracle {
  /* ─────────────────────────── immutables ─────────────────────────── */

  /// @inheritdoc IV3ProviderOracle
  address public immutable ADAPTER;
  /// @inheritdoc IV3ProviderOracle
  address public immutable PROVIDER_SHARE;

  address public immutable TOKEN0;
  address public immutable TOKEN1;
  uint8 public immutable DECIMALS0;
  uint8 public immutable DECIMALS1;

  /// @dev Decimals of the priced share token (ERC4626 ⇒ == the accounting asset's decimals). Moolah reads
  ///      `collateralToken.decimals()` to interpret peek(), so the share price must be quoted per ONE WHOLE
  ///      share (10 ** SHARE_DECIMALS share-wei), not hardcoded to 1e18.
  uint8 public immutable SHARE_DECIMALS;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  uint256 internal constant BPS = 10_000;
  /// @dev Hard cap on the configurable haircut (10%).
  uint256 public constant MAX_HAIRCUT_BPS = 1_000;

  /* ──────────────────────────── storage ───────────────────────────── */

  /// @dev Resilient oracle pricing TOKEN0/TOKEN1 (and any non-share token, delegated).
  address public resilientOracle;

  /// @inheritdoc IV3ProviderOracle
  uint256 public haircutBps;

  uint256[50] private __gap;

  /* ─────────────────────────── events/errors ──────────────────────── */

  event HaircutChanged(uint256 haircutBps);

  error ZeroAddress();
  error InvalidHaircut();
  error ZeroPrice();
  error AdapterPairMismatch();
  error ShareAdapterMismatch();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _adapter, address _providerShare, address _token0, address _token1) {
    if (_adapter == address(0) || _providerShare == address(0)) revert ZeroAddress();
    if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
    // The oracle's tokens (and their order) must match the adapter's, so peek() prices exactly the
    // composition the adapter reports.
    if (_token0 != IV3DexAdapter(_adapter).TOKEN0() || _token1 != IV3DexAdapter(_adapter).TOKEN1())
      revert AdapterPairMismatch();
    // Cross-validate the wiring: the priced share must be the vault bound to THIS adapter, so peek()
    // reads composition from the same adapter that issued the share. Guards against a silent mis-wire.
    if (IV3Provider(_providerShare).ADAPTER() != _adapter) revert ShareAdapterMismatch();
    ADAPTER = _adapter;
    PROVIDER_SHARE = _providerShare;
    TOKEN0 = _token0;
    TOKEN1 = _token1;
    DECIMALS0 = IERC20Metadata(_token0).decimals();
    DECIMALS1 = IERC20Metadata(_token1).decimals();
    SHARE_DECIMALS = IERC20Metadata(_providerShare).decimals();
    _disableInitializers();
  }

  function initialize(
    address _admin,
    address _manager,
    address _resilientOracle,
    uint256 _haircutBps
  ) external initializer {
    if (_admin == address(0) || _manager == address(0) || _resilientOracle == address(0)) revert ZeroAddress();
    if (_haircutBps > MAX_HAIRCUT_BPS) revert InvalidHaircut();

    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);

    resilientOracle = _resilientOracle;
    haircutBps = _haircutBps;
  }

  /* ─────────────────────── IOracle implementation ─────────────────── */

  /// @inheritdoc IOracle
  function peek(address token) external view returns (uint256) {
    if (token != PROVIDER_SHARE) {
      return IOracle(resilientOracle).peek(token);
    }

    uint256 supply = IERC20(PROVIDER_SHARE).totalSupply();
    if (supply == 0) return 0; // pre-market

    // Fair composition from the adapter, taken at its manipulation-resistant fair price
    // (exchange-rate-implied for slisBNB; pool TWAP clamped to the rate for wstETH/wbETH; never raw
    // pool spot/slot0).
    (uint256 total0, uint256 total1) = IV3DexAdapter(ADAPTER).positionAmountsAt(
      IV3DexAdapter(ADAPTER).fairSqrtPriceX96()
    );

    // AUDIT NOTE — leg prices are RATE-CONSISTENT with the composition above, NOT an independent
    // second market price. By deployment invariant, the resilient oracle prices the LST leg (TOKEN0 =
    // slisBNB / wstETH / wbETH) rate-derived from the SAME on-chain exchange rate used for the
    // composition:
    //     peek(LST) == peek(underlying WBNB/WETH) × exchangeRate / 1e18
    //   (slisBNB → StakeManager.convertSnBnbToBnb; wstETH → stEthPerToken; wbETH → exchangeRate)
    // i.e. NOT a secondary-market price. So there is no market-vs-rate divergence between the two and
    // the stETH/ETH (or wbETH/ETH) depeg is excluded from the price by construction (carried by LLTV).
    // Verified on-chain to the wei (e.g. peek(wstETH) == peek(WETH) × wstETH.stEthPerToken() / 1e18).
    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8 decimals (rate-derived for the LST leg)
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8 decimals
    if (price0 == 0 || price1 == 0) revert ZeroPrice(); // finding D

    uint256 totalValue = (total0 * price0) / (10 ** DECIMALS0) + (total1 * price1) / (10 ** DECIMALS1);
    if (totalValue == 0) revert ZeroPrice(); // finding D

    // 8-decimal USD price per ONE WHOLE share (10 ** SHARE_DECIMALS share-wei) — Moolah interprets peek()
    // using collateralToken.decimals() — minus the conservative haircut.
    uint256 raw = (totalValue * (10 ** SHARE_DECIMALS)) / supply;
    return (raw * (BPS - haircutBps)) / BPS;
  }

  /// @inheritdoc IOracle
  function getTokenConfig(address token) external view returns (TokenConfig memory) {
    if (token != PROVIDER_SHARE) {
      return IOracle(resilientOracle).getTokenConfig(token);
    }
    return
      TokenConfig({
        asset: PROVIDER_SHARE,
        oracles: [address(this), address(0), address(0)],
        enableFlagsForOracles: [true, false, false],
        timeDeltaTolerance: 0
      });
  }

  /* ──────────────────────────── manager ───────────────────────────── */

  /// @inheritdoc IV3ProviderOracle
  function setHaircutBps(uint256 _haircutBps) external onlyRole(MANAGER) {
    if (_haircutBps > MAX_HAIRCUT_BPS) revert InvalidHaircut();
    haircutBps = _haircutBps;
    emit HaircutChanged(_haircutBps);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

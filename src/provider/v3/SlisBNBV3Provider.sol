// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMoolah, Id } from "moolah/interfaces/IMoolah.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";

import { V3Provider } from "./V3Provider.sol";
import { IV3DexAdapter } from "../interfaces/IV3DexAdapter.sol";
import { ISlisBNBV3DexAdapter } from "../interfaces/ISlisBNBV3DexAdapter.sol";
import { ISlisBNBxMinter } from "../../utils/interfaces/ISlisBNBx.sol";

/**
 * @title SlisBNBV3Provider
 * @author Lista DAO
 * @notice slisBNB/BNB vault: thin slisBNB specialization of {V3Provider}. The DEX / rate / rebalance
 *         logic lives in the SlisBNBV3DexAdapter; this vault adds slisBNBx reward mirroring and the
 *         BOT-gated rebalance entry that forwards to the adapter.
 */
contract SlisBNBV3Provider is V3Provider {
  /// @dev Virtual address used by the resilient oracle to price native BNB.
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /* ──────────────────────────── storage ───────────────────────────── */

  mapping(address => mapping(Id => uint256)) public userMarketDeposit;
  mapping(address => uint256) public userTotalDeposit;
  address public slisBNBxMinter;

  /* ───────────────────────────── events ───────────────────────────── */

  event SlisBNBxMinterChanged(address indexed minter);

  /* ───────────────────────────── errors ───────────────────────────── */

  error LengthMismatch();

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

  /* ─────────────────────────── rebalance ──────────────────────────── */

  /// @notice Recenter the managed position to the exchange-rate-derived range (adapter does the work).
  ///         BOT-gated here; the adapter's rebalance is onlyProvider. `swapData` is built by the BOT
  ///         backend and encodes (swapPair, sellToken0, amountIn, amountOutMin, innerSwapData) for the
  ///         inventory-conversion swap (empty ⇒ recenter only).
  function rebalance(
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 minLiquidity,
    uint256 deadline,
    bytes calldata swapData
  ) external onlyRole(BOT) nonReentrant {
    ISlisBNBV3DexAdapter(ADAPTER).rebalance(minAmount0, minAmount1, minLiquidity, deadline, swapData);
  }

  /* ─────────────────── slisBNBx: sync / view ──────────────────────── */

  /// @notice User's deposited collateral value in BNB (18 decimals). ISlisBNBxModule callback.
  ///         Valued at the adapter's exchange-rate fair price (manipulation-resistant).
  function getUserBalanceInBnb(address account) external view returns (uint256) {
    uint256 shares = userTotalDeposit[account];
    if (shares == 0) return 0;
    uint256 supply = totalSupply();
    if (supply == 0) return 0;

    (uint256 total0, uint256 total1) = IV3DexAdapter(ADAPTER).positionAmountsAt(
      IV3DexAdapter(ADAPTER).fairSqrtPriceX96()
    );

    uint256 user0 = (total0 * shares) / supply;
    uint256 user1 = (total1 * shares) / supply;

    uint256 price0 = IOracle(resilientOracle).peek(TOKEN0); // 8-decimal USD
    uint256 price1 = IOracle(resilientOracle).peek(TOKEN1); // 8-decimal USD
    uint256 bnbPrice = IOracle(resilientOracle).peek(BNB_ADDRESS); // 8-decimal USD

    uint256 value0 = (user0 * price0 * 1e18) / (10 ** DECIMALS0);
    uint256 value1 = (user1 * price1 * 1e18) / (10 ** DECIMALS1);
    return (value0 + value1) / bnbPrice;
  }

  function syncUserBalance(Id id, address account) external {
    if (MOOLAH.idToMarketParams(id).collateralToken != address(this)) revert InvalidMarket();
    _syncPosition(id, account);
  }

  function bulkSyncUserBalance(Id[] calldata ids, address[] calldata accounts) external {
    if (ids.length != accounts.length) revert LengthMismatch();
    for (uint256 i = 0; i < accounts.length; i++) {
      if (MOOLAH.idToMarketParams(ids[i]).collateralToken != address(this)) revert InvalidMarket();
      _syncPosition(ids[i], accounts[i]);
    }
  }

  /* ──────────────────── manager: slisBNBxMinter ───────────────────── */

  function setSlisBNBxMinter(address _slisBNBxMinter) external onlyRole(MANAGER) {
    slisBNBxMinter = _slisBNBxMinter;
    emit SlisBNBxMinterChanged(_slisBNBxMinter);
  }

  /* ────────────────────────── hook override ───────────────────────── */

  function _afterCollateralChange(Id id, address account) internal override {
    _syncPosition(id, account);
  }

  function _syncPosition(Id id, address account) internal {
    uint256 current = MOOLAH.position(id, account).collateral;
    if (current >= userMarketDeposit[account][id]) {
      userTotalDeposit[account] += current - userMarketDeposit[account][id];
    } else {
      userTotalDeposit[account] -= userMarketDeposit[account][id] - current;
    }
    userMarketDeposit[account][id] = current;

    if (slisBNBxMinter != address(0)) {
      ISlisBNBxMinter(slisBNBxMinter).rebalance(account);
    }
  }
}

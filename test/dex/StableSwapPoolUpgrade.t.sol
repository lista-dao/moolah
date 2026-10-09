// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { IStableSwap } from "../../src/dex/interfaces/IStableSwap.sol";
import { IStableSwapLP } from "../../src/dex/interfaces/IStableSwapLP.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

/// @title StableSwapPoolUpgrade
/// @notice Upgrade-differential harness: fingerprints every live BSC pool, upgrades the proxies, then
///         re-fingerprints and asserts the numbers borrow / repay / liquidation depend on are preserved.
/// @dev This base class performs an IDENTITY upgrade — it redeploys the implementation the proxies are
///      already on, so every assertion takes its strictest form (nothing may change at all). That
///      exercises the harness, the admin path and the storage layout independently of any behaviour
///      change. Subclass it and override {_deployImplementation} and {_maxVpRebaseBps} to point the same
///      assertions at a different implementation.
contract StableSwapPoolUpgradeTest is Test {
  uint256 constant FORK_BLOCK = 122_380_000;

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  uint256 constant PRECISION = 1e18;

  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // sole DEFAULT_ADMIN_ROLE
  address constant SS_FACTORY = 0xDE9c8E1536989d8c3817afDabC37C0fb44cB49b4;
  bytes32 constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  struct Pool {
    string name;
    address pool;
    address provider; // SmartProvider — doubles as the market oracle
    address collateral;
  }

  /// @dev Everything the rest of the protocol can observe about a pool.
  struct Fingerprint {
    address token;
    address coin0;
    address coin1;
    uint256 balance0;
    uint256 balance1;
    uint256 supply;
    uint256 virtualPrice;
    uint256 collateralPrice; // SmartProvider.peek(collateral)
    uint256 redeemOut0; // what a fixed LP slice redeems for
    uint256 redeemOut1;
  }

  Pool[] internal pools;

  function setUp() public virtual {
    vm.createSelectFork(vm.envString("BSC_RPC"), FORK_BLOCK);

    pools.push(
      Pool(
        "lisAster/ASTER",
        0x510D69b25A2177EDdCe9becdB0A66a511C944840,
        0x1cc913Cde4dF80d271230F615482c1270c0a56C8,
        0xC970dc3aF680C2F316b821842E5782a05e886a90
      )
    );
    pools.push(
      Pool(
        "USD1/USDT",
        0x723ccd2FB5897673Ad108706578886baA15d7242,
        0x791cd65F2B8cB7cA3a6c1C4D28A0b23D8E566495,
        0x091e6Ed7794d74b73081D32cAb59fa47ff15418d
      )
    );
    pools.push(
      Pool(
        "solvBTC/BTCB",
        0x45409865870f0CBC71c01CC00fF8c0b2DE3EB7D9,
        0xA5F53ca56d87d7d4fEC508665D23f29bfb2749DB,
        0x6f4d7532A402D76F552E1F047Ff7e23bFe1A9f03
      )
    );
    pools.push(
      Pool(
        "slisBNB/BNB",
        0x3DcEA6AFBA8af84b25F1f8947058AF1ac4c06131,
        0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE,
        0x719f6445cdAC08B84611D0F19d733F57214bcfee
      )
    );
    pools.push(
      Pool(
        "lisUSD/USDT",
        0x8df7891fb2Cb3e98C7AB3cfB4d9A59FbCC63c956,
        0x6A39B04f8a7DB71Cee17f9978004C028bfF2e144,
        0x6c7EbA17dDB5D0435FCFb9053BB3087c1d10beB3
      )
    );
    pools.push(
      Pool(
        "U/USDT",
        0x6783a05B98Cb83c3f456197A035b9C17a9d57388,
        0x9994D77E5cdcAD9f9055b13402A7BF8C24d4C841,
        0xbBD3e74E69e6BDDDA8e5AAdC1460611A8f7cd05a
      )
    );
    pools.push(
      Pool(
        "USDC/USDT",
        0xF5448fC2bEB9324900d08225fE4530bA3bBf654f,
        0x5fD3971104cF3bAB1dC89EF904Da26F54f75C06B,
        0x23BC296d67619eA11C9a8B49B8C396B798AF3330
      )
    );
  }

  /* ------------------------------------------------------------------ *
   *  hooks
   * ------------------------------------------------------------------ */

  /// @dev The implementation `pool` is upgraded to. By default the one it is already running, read
  ///      straight out of its ERC-1967 slot, which makes the base run an exact identity upgrade.
  function _implementationFor(address pool) internal virtual returns (address) {
    return address(uint160(uint256(vm.load(pool, ERC1967_IMPLEMENTATION_SLOT))));
  }

  /// @dev Allowed upward movement of `get_virtual_price` across the upgrade, in bps. Zero for an
  ///      identity upgrade.
  function _maxVpRebaseBps() internal view virtual returns (uint256) {
    return 0;
  }

  /// @dev Upgrade every pool in the table, each to whatever {_implementationFor} returns for it.
  function _upgradeAll() internal {
    for (uint256 i = 0; i < pools.length; i++) {
      address impl = _implementationFor(pools[i].pool);
      vm.prank(TIMELOCK);
      UUPSUpgradeable(pools[i].pool).upgradeToAndCall(impl, "");
    }
  }

  /* ------------------------------------------------------------------ *
   *  the differential
   * ------------------------------------------------------------------ */

  /// @notice Upgrading must leave storage, redemption amounts and the oracle price intact.
  function test_upgrade_preservesObservableState() public {
    uint256 n = pools.length;
    Fingerprint[] memory before = new Fingerprint[](n);
    for (uint256 i = 0; i < n; i++) before[i] = _fingerprint(pools[i]);

    _upgradeAll();

    for (uint256 i = 0; i < n; i++) {
      Fingerprint memory a = before[i];
      Fingerprint memory b = _fingerprint(pools[i]);
      string memory nm = pools[i].name;

      // --- storage layout survived the upgrade ---
      assertEq(b.token, a.token, string.concat(nm, ": token moved"));
      assertEq(b.coin0, a.coin0, string.concat(nm, ": coin0 moved"));
      assertEq(b.coin1, a.coin1, string.concat(nm, ": coin1 moved"));
      assertEq(b.balance0, a.balance0, string.concat(nm, ": balance0 moved"));
      assertEq(b.balance1, a.balance1, string.concat(nm, ": balance1 moved"));
      assertEq(b.supply, a.supply, string.concat(nm, ": LP supply moved"));

      // --- redemption is the number users and liquidators actually receive ---
      assertEq(b.redeemOut0, a.redeemOut0, string.concat(nm, ": redeem leg0 changed"));
      assertEq(b.redeemOut1, a.redeemOut1, string.concat(nm, ": redeem leg1 changed"));

      // --- collateral pricing may only re-base upward, within the documented bound ---
      _assertRebase(nm, a.virtualPrice, b.virtualPrice, "virtual price");
      _assertRebase(nm, a.collateralPrice, b.collateralPrice, "collateral price");
    }
  }

  /// @notice A real redemption still pays exactly pro rata after the upgrade.
  /// @dev `withdrawCollateral` and the liquidator's `redeemLpCollateral` both route through
  ///      `remove_liquidity`; this executes it for real rather than only reading the preview.
  function test_upgrade_redemptionStillPaysProRata() public {
    _upgradeAll();

    address redeemer = makeAddr("upgradeRedeemer");

    for (uint256 i = 0; i < pools.length; i++) {
      Pool memory cfg = pools[i];
      IStableSwap pool = IStableSwap(cfg.pool);
      address lpToken = pool.token();
      if (IStableSwapLP(lpToken).totalSupply() == 0) continue;

      uint256 lpAmount = IERC20(lpToken).balanceOf(cfg.provider) / 1000;
      if (lpAmount == 0) continue;

      // Redeem from a plain EOA rather than the SmartProvider: the provider's `receive()` re-reads
      // `dex` under the pool's `bnb_gas` stipend (4029), which only fits when that slot is already
      // warm — true in production, not when a test pokes the pool directly. Mint through the pool's
      // own minter right so nothing is faked.
      vm.prank(cfg.pool);
      IStableSwapLP(lpToken).mint(redeemer, lpAmount);

      uint256 supply = IStableSwapLP(lpToken).totalSupply();
      uint256[2] memory expected;
      uint256[2] memory beforeBal;
      for (uint256 j = 0; j < 2; j++) {
        expected[j] = (pool.balances(j) * lpAmount) / supply;
        beforeBal[j] = _balanceOf(pool.coins(j), redeemer);
      }

      vm.prank(redeemer);
      pool.remove_liquidity(lpAmount, [uint256(0), uint256(0)]);

      for (uint256 j = 0; j < 2; j++) {
        uint256 received = _balanceOf(pool.coins(j), redeemer) - beforeBal[j];
        assertEq(received, expected[j], string.concat(cfg.name, ": post-upgrade payout is not pro rata"));
      }
    }
  }

  /* ------------------------------------------------------------------ *
   *  helpers
   * ------------------------------------------------------------------ */

  function _fingerprint(Pool memory cfg) internal returns (Fingerprint memory fp) {
    IStableSwap pool = IStableSwap(cfg.pool);
    fp.token = pool.token();
    fp.coin0 = pool.coins(0);
    fp.coin1 = pool.coins(1);
    fp.balance0 = pool.balances(0);
    fp.balance1 = pool.balances(1);
    fp.supply = IStableSwapLP(fp.token).totalSupply();
    if (fp.supply == 0) return fp;

    fp.virtualPrice = pool.get_virtual_price();
    fp.collateralPrice = IOracle(cfg.provider).peek(cfg.collateral);

    // Preview a redemption without keeping the state change.
    uint256 lpAmount = IERC20(fp.token).balanceOf(cfg.provider) / 1000;
    if (lpAmount == 0) return fp;

    uint256 snap = vm.snapshotState();

    // Redeem from a plain EOA rather than from the provider itself. The provider's `receive()` re-reads
    // `dex` from storage, and the pool forwards only `bnb_gas`, which leaves no headroom once that slot
    // is cold. Moving the LP first keeps the supply and therefore the payout identical, so the
    // fingerprint measures the same numbers the provider would have received.
    address redeemer = makeAddr("fingerprintRedeemer");
    vm.prank(cfg.provider);
    IERC20(fp.token).transfer(redeemer, lpAmount);

    uint256 b0 = _balanceOf(fp.coin0, redeemer);
    uint256 b1 = _balanceOf(fp.coin1, redeemer);
    vm.prank(redeemer);
    pool.remove_liquidity(lpAmount, [uint256(0), uint256(0)]);
    fp.redeemOut0 = _balanceOf(fp.coin0, redeemer) - b0;
    fp.redeemOut1 = _balanceOf(fp.coin1, redeemer) - b1;

    vm.revertToState(snap);
  }

  /// @dev Prices may only move upward, and by at most {_maxVpRebaseBps}. A downward move would cut
  ///      collateral value at the upgrade block and could liquidate live positions.
  function _assertRebase(string memory nm, uint256 before_, uint256 after_, string memory what) internal {
    if (before_ == 0) return;
    assertGe(after_, before_, string.concat(nm, ": ", what, " must not decrease"));
    uint256 bps = ((after_ - before_) * 10_000) / before_;
    assertLe(bps, _maxVpRebaseBps(), string.concat(nm, ": ", what, " re-based beyond the bound"));

    // Surface the actual move: a green run with a generous bound proves nothing on its own.
    emit log_named_string("rebase", string.concat(nm, " / ", what));
    emit log_named_uint("  before", before_);
    emit log_named_uint("  after ", after_);
    emit log_named_uint("  bps   ", bps);
  }

  function _balanceOf(address coin, address who) internal view returns (uint256) {
    return coin == BNB_ADDRESS ? who.balance : IERC20(coin).balanceOf(who);
  }
}

/// @notice Points the harness at the newly compiled {StableSwapPool}: the live proxies are upgraded to
///         it and every assertion in the base class is re-run.
/// @dev The base fingerprints each pool on the implementation the proxy is actually running — the one
///      deployed on chain — then upgrades and re-fingerprints, so storage preservation, redemption
///      amounts and collateral pricing are compared old-vs-new rather than new-vs-new.
contract StableSwapPoolUpgradeDiffTest is StableSwapPoolUpgradeTest {
  address private newImpl;

  function _implementationFor(address) internal override returns (address) {
    if (newImpl == address(0)) newImpl = address(new StableSwapPool(SS_FACTORY));
    return newImpl;
  }

  /// @dev `get_virtual_price` is derived from the reserve value rather than an invariant. The largest
  ///      measured move across the live pools was +0.3546%; 40bps leaves headroom. The base also asserts
  ///      the move is never negative — a downward move would cut collateral value at the upgrade block
  ///      and could liquidate live positions.
  function _maxVpRebaseBps() internal pure override returns (uint256) {
    return 40;
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";
import { IV3Provider } from "../../src/provider/interfaces/IV3Provider.sol";

import { SlisBNBV3ProviderTest } from "./SlisBNBV3Provider.t.sol";

/**
 * @title V3Provider C-1 regression — deposit-refund reentrancy must NOT inflate the share oracle
 * @notice C-1 (Critical): V3Provider.deposit forwarded tokens to the adapter and called addLiquidity
 *         — which refunded unused WBNB via a native-BNB call to the DEPOSITOR — BEFORE minting and
 *         supplying the new shares. During that refund callback:
 *           - adapter NAV already included the freshly-added liquidity, but
 *           - totalSupply() was still the OLD supply (shares minted later),
 *         so SlisBNBV3ProviderOracle.peek(share) reported a transiently inflated price. Moolah was NOT
 *         locked at that point (supplyCollateral ran later), so the attacker reentered Moolah.borrow
 *         and over-borrowed against its pre-existing collateral, leaving bad debt once price normalized.
 *
 *         Fix: the adapter now refunds to the VAULT, and the vault forwards the refund to the depositor
 *         only AFTER _mint + supplyCollateral. No external (native-BNB) call happens while NAV and
 *         totalSupply are inconsistent, so the oracle can never be transiently inflated.
 *
 *         This test still drives the full attack (deposit -> refund reentry -> borrow), but now asserts
 *         the attack is NEUTRALIZED: the price read during the refund callback equals the normal price,
 *         and the attacker's position stays healthy (no bad debt). It FAILS against the pre-fix code
 *         (26x inflation, insolvent attacker) and PASSES against the fixed code.
 */
contract V3ProviderReentrancyPoC is SlisBNBV3ProviderTest {
  Attacker attacker;
  address constant victimB = address(0xB0B); // receives the big deposit's collateral (recoverable)

  function test_C1_depositRefundReentrancy_neutralized() public {
    // 1) Bootstrap a small shared position so supply > 0.
    _deposit(user, 1 ether, 1 ether);

    // 2) Deploy the attacker and give it a small pre-existing collateral position in the market.
    attacker = new Attacker(address(provider), MOOLAH_PROXY, address(providerOracle), SLISBNB, WBNB, LISUSD);
    attacker.setMarket(marketParams);

    deal(SLISBNB, address(attacker), 1 ether);
    deal(WBNB, address(attacker), 1 ether);
    attacker.predeposit(1 ether, 1 ether); // attacker now holds collateral, priced at the normal rate

    uint256 colA = _collateral(address(attacker));
    assertGt(colA, 0, "attacker has pre-existing collateral");

    uint256 peekNormal = providerOracle.peek(address(provider));

    // 3) Fund the big imbalanced deposit: lots of WBNB so a large WBNB refund fires the native
    //    callback, while still adding large liquidity (so NAV jumps).
    uint256 bigSlis = 50 ether;
    uint256 bigWbnb = 150 ether; // ~100 used + ~50 refunded
    deal(SLISBNB, address(attacker), bigSlis);
    deal(WBNB, address(attacker), bigWbnb);

    // 4) Execute the attack: deposit (onBehalf = victimB) -> refund reentry -> borrow.
    attacker.attack(bigSlis, bigWbnb, victimB);

    uint256 peekDuring = attacker.peekDuring();
    uint256 peekAfter = providerOracle.peek(address(provider));

    emit log_named_uint("peek normal (pre-attack)", peekNormal);
    emit log_named_uint("peek DURING refund reentry", peekDuring);
    emit log_named_uint("peek after deposit settles", peekAfter);

    // ── Proofs the attack is neutralized ────────────────────────────────────
    // (a) The refund callback fires AFTER mint+supply, so NAV and totalSupply are consistent: the
    //     price observed mid-deposit must match the settled/normal price (no transient inflation).
    assertApproxEqRel(peekDuring, peekNormal, 1e16, "peek during refund must equal normal price (<=1%)");
    assertApproxEqRel(peekDuring, peekAfter, 1e16, "peek during refund must equal settled price (<=1%)");

    // (b) Because the price was never inflated, any reentrant borrow was fairly priced: the attacker's
    //     position is solvent — no bad debt is left to the protocol.
    assertTrue(
      moolah.isHealthy(marketParams, marketId, address(attacker)),
      "attacker position must remain solvent (no bad debt)"
    );

    // (c) The deposit itself still works: the big collateral landed on the onBehalf account.
    assertGt(_collateral(victimB), colA * 10, "deposit still credits onBehalf collateral");
  }
}

/// @dev Malicious depositor: reenters Moolah.borrow from its receive() during the WBNB refund.
contract Attacker {
  using MarketParamsLib for MarketParams;

  IV3Provider public immutable provider;
  IMoolah public immutable moolah;
  IOracle public immutable oracle;
  address public immutable slis;
  address public immutable wbnb;
  address public immutable lisusd;

  MarketParams public mp;
  bool armed;
  uint256 public peekDuring;

  constructor(address _provider, address _moolah, address _oracle, address _slis, address _wbnb, address _lisusd) {
    provider = IV3Provider(_provider);
    moolah = IMoolah(_moolah);
    oracle = IOracle(_oracle);
    slis = _slis;
    wbnb = _wbnb;
    lisusd = _lisusd;
  }

  function setMarket(MarketParams calldata _mp) external {
    mp = _mp;
  }

  /// @dev Build a normally-priced collateral position (armed == false, so receive() is inert).
  function predeposit(uint256 a0, uint256 a1) external {
    IERC20(slis).approve(address(provider), type(uint256).max);
    IERC20(wbnb).approve(address(provider), type(uint256).max);
    provider.deposit(mp, a0, a1, 0, 0, address(this));
  }

  /// @dev The malicious deposit. onBehalf = a separate (recoverable) account.
  function attack(uint256 a0, uint256 a1, address onBehalf) external {
    armed = true;
    provider.deposit(mp, a0, a1, 0, 0, onBehalf);
    armed = false;
  }

  /// @dev WBNB refund is unwrapped and delivered here as native BNB mid-deposit -> attempt reentry.
  receive() external payable {
    if (!armed) return;
    armed = false; // single shot

    peekDuring = oracle.peek(address(provider)); // post-fix: equals the normal (un-inflated) price

    // Attempt to borrow ~60% of this account's collateral value at the observed price. Wrapped in
    // try/catch so the deposit completes regardless of whether the borrow succeeds (it will, but at a
    // fair price post-fix, leaving a healthy position) or reverts.
    Position memory p = moolah.position(mp.id(), address(this));
    uint256 col = p.collateral;
    uint256 sharePrice = peekDuring; // 8-dec USD per 1e18 share
    uint256 loanPrice = oracle.peek(lisusd); // ~1e8
    uint256 borrowAssets = (col * sharePrice * 60) / (loanPrice * 100);

    try moolah.borrow(mp, borrowAssets, 0, address(this), address(this)) {} catch {}
  }
}

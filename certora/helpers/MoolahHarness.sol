// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import "moolah/Moolah.sol";
import "moolah/libraries/SharesMathLib.sol";
import "moolah/libraries/MarketParamsLib.sol";

contract MoolahHarness is Moolah {
  using MarketParamsLib for MarketParams;

  // NOTE: Moolah is an upgradeable (UUPS) contract. Its constructor only calls
  // `_disableInitializers()`, and state is configured via
  // `initialize(admin, manager, pauser, minLoanValue)` — there is no
  // `constructor(address newOwner)` like Morpho Blue. The harness therefore inherits the
  // no-arg constructor; initialization for verification (roles, minLoanValue, ...) must be
  // arranged on the Certora side. See certora/README.md.

  function idToMarketParams_(Id id) external view returns (MarketParams memory) {
    return idToMarketParams[id];
  }

  function market_(Id id) external view returns (Market memory) {
    return market[id];
  }

  function position_(Id id, address user) external view returns (Position memory) {
    return position[id][user];
  }

  function totalSupplyAssets(Id id) external view returns (uint256) {
    return market[id].totalSupplyAssets;
  }

  function totalSupplyShares(Id id) external view returns (uint256) {
    return market[id].totalSupplyShares;
  }

  function totalBorrowAssets(Id id) external view returns (uint256) {
    return market[id].totalBorrowAssets;
  }

  function totalBorrowShares(Id id) external view returns (uint256) {
    return market[id].totalBorrowShares;
  }

  function supplyShares(Id id, address account) external view returns (uint256) {
    return position[id][account].supplyShares;
  }

  function borrowShares(Id id, address account) external view returns (uint256) {
    return position[id][account].borrowShares;
  }

  function collateral(Id id, address account) external view returns (uint256) {
    return position[id][account].collateral;
  }

  function lastUpdate(Id id) external view returns (uint256) {
    return market[id].lastUpdate;
  }

  function fee(Id id) external view returns (uint256) {
    return market[id].fee;
  }

  function virtualTotalSupplyAssets(Id id) external view returns (uint256) {
    return market[id].totalSupplyAssets + SharesMathLib.VIRTUAL_ASSETS;
  }

  function virtualTotalSupplyShares(Id id) external view returns (uint256) {
    return market[id].totalSupplyShares + SharesMathLib.VIRTUAL_SHARES;
  }

  function virtualTotalBorrowAssets(Id id) external view returns (uint256) {
    return market[id].totalBorrowAssets + SharesMathLib.VIRTUAL_ASSETS;
  }

  function virtualTotalBorrowShares(Id id) external view returns (uint256) {
    return market[id].totalBorrowShares + SharesMathLib.VIRTUAL_SHARES;
  }

  function isHealthy(MarketParams memory marketParams, address user) external view returns (bool) {
    return _isHealthy(marketParams, marketParams.id(), user);
  }

  // Verification-time initializer. Moolah's real `initialize(...)` is guarded by the
  // `initializer` modifier, which the implementation constructor permanently disables via
  // `_disableInitializers()` — so the prover cannot reach an initialized state through it.
  // This helper reproduces the post-`initialize` state (roles + minLoanValue) directly, so
  // rules can start from a sane, initialized contract instead of an all-zero one. It is NOT
  // part of Moolah and exists only for verification; it must be excluded from parametric
  // `method f` rules (see certora/specs/ProxyFilters.spec :: isUpgradeOrInit).
  function setUpInitializedState(address admin, address manager, address pauser, uint256 minLoanValue_) external {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);
    minLoanValue = minLoanValue_;
  }

  // Exposes the UUPS upgrade-authorization gate. `upgradeToAndCall` itself carries an
  // `onlyProxy` guard that always reverts when the implementation is verified directly (no
  // proxy in the scene), which would make any upgrade-auth rule vacuous. This wrapper lets
  // the prover reason about `_authorizeUpgrade` (restricted to DEFAULT_ADMIN_ROLE) directly.
  // See certora/specs/AccessControl.spec :: onlyAdminCanAuthorizeUpgrade.
  function authorizeUpgrade_(address newImplementation) external {
    _authorizeUpgrade(newImplementation);
  }

  // Exposes the (private-backed) ReentrancyGuard status. The `nonReentrant` guard reverts when
  // `_status == ENTERED`; on the directly-verified implementation that storage is never
  // initialized, so the prover may pick ENTERED and spuriously revert every guarded function.
  // Liveness rules `require !reentrancyGuardEntered_()` (and !paused()) to assume a normal
  // between-transactions state. See certora/specs/Liveness.spec.
  function reentrancyGuardEntered_() external view returns (bool) {
    return _reentrancyGuardEntered();
  }
}

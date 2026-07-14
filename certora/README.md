> **Moolah note.** This suite was migrated from Morpho Blue to verify the Moolah protocol
> (`src/moolah/`), which is a fork of Morpho Blue. Harnesses now extend `Moolah`
> (`MoolahHarness`) and callbacks are `onMoolah*`. The rule documentation below is inherited
> from Morpho Blue and still describes the shared core logic; see the
> [**Migration status**](#migration-status) section at the end for what has and hasn't been
> adapted to Moolah yet.

This folder contains the verification of the Morpho Blue protocol using CVL, Certora's Verification Language.

The core concepts of the Morpho Blue protocol are described in the Morpho Blue whitepaper.
These concepts have been verified using CVL.
We first give a [high-level description](#high-level-description) of the verification and then describe the [folder and file structure](#folder-and-file-structure) of the specification files.

# High-level description

The Morpho Blue protocol allows users to take out collateralized loans on ERC20 tokens.

## ERC20 tokens and transfers

For a given market, Morpho Blue relies on the fact that the tokens involved respect the ERC20 standard.
In particular, in case of a transfer, it is assumed that the balance of Morpho Blue increases or decreases (depending if it's the recipient or the sender) of the amount transferred.

The file [Transfer.spec](specs/Transfer.spec) defines a summary of the transfer functions.
This summary is taken as the reference implementation to check that the balance of the Morpho Blue contract changes as expected.

```solidity
function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    if (from == currentContract) {
        balance[token] = require_uint256(balance[token] - amount);
    }
    if (to == currentContract) {
        balance[token] = require_uint256(balance[token] + amount);
    }
}
```

where `balance` is the ERC20 balance of the Morpho Blue contract.

The verification is done for the most common implementations of the ERC20 standard, for which we distinguish three different implementations:

- [ERC20Standard](dispatch/ERC20Standard.sol) which respects the standard and reverts in case of insufficient funds or in case of insufficient allowance.
- [ERC20NoRevert](dispatch/ERC20NoRevert.sol) which respects the standard but does not revert (and returns false instead).
- [ERC20USDT](dispatch/ERC20USDT.sol) which does not strictly respect the standard because it omits the return value of the `transfer` and `transferFrom` functions.

Additionally, Morpho Blue always goes through a custom transfer library to handle ERC20 tokens, notably in all the above cases.
This library reverts when the transfer is not successful, and this is checked for the case of insufficient funds or insufficient allowance.
The use of the library can make it difficult for the provers, so the summary is sometimes used in other specification files to ease the verification of rules that rely on the transfer of tokens.

## Markets

The Morpho Blue contract is a singleton contract that defines different markets.
Markets on Morpho Blue depend on a pair of assets, the loan token that is supplied and borrowed, and the collateral token.
Taking out a loan requires to deposit some collateral, which stays idle in the contract.
Additionally, every loan token that is not borrowed also stays idle in the contract.
This is verified by the following property:

```solidity
invariant idleAmountLessThanBalance(address token)
    idleAmount[token] <= balance[token]
```

where `idleAmount` is the sum over all the markets of: the collateral amounts plus the supplied amounts minus the borrowed amounts.
In effect, this means that funds can only leave the contract through borrows and withdrawals.

Additionally, it is checked that on a given market the borrowed amounts cannot exceed the supplied amounts.

```solidity
invariant borrowLessThanSupply(MorphoHarness.Id id)
    totalBorrowAssets(id) <= totalSupplyAssets(id);
```

This property, along with the previous one ensures that other markets can only impact the balance positively.
Said otherwise, markets are independent: tokens from a given market cannot be impacted by operations done in another market.

## Shares

When supplying on Morpho Blue, interest is earned over time, and the distribution is implemented through a shares mechanism.
Shares increase in value as interest is accrued.
The share mechanism is implemented symmetrically for the borrow side: a share of borrow increasing in value over time represents additional owed interest.
The rule `accrueInterestIncreasesSupplyExchangeRate` checks this property for the supply side with the following statement.

```solidity
    // Check that the exchange rate increases: assetsBefore/sharesBefore <= assetsAfter/sharesAfter
    assert assetsBefore * sharesAfter <= assetsAfter * sharesBefore;
```

where `assetsBefore` and `sharesBefore` represents respectively the supplied assets and the supplied shares before accruing the interest. Similarly, `assetsAfter` and `sharesAfter` represent the supplied assets and shares after an interest accrual.

The accounting of the shares mechanism relies on another variable to store the total number of shares, in order to compute what is the relative part of each user.
This variable needs to be kept up to date at each corresponding interaction, and it is checked that this accounting is done properly.
For example, for the supply side, this is done by the following invariant.

```solidity
invariant sumSupplySharesCorrect(MorphoHarness.Id id)
    to_mathint(totalSupplyShares(id)) == sumSupplyShares[id];
```

where `sumSupplyShares` only exists in the specification, and is defined to be automatically updated whenever any of the shares of the users are modified.

## Positions health and liquidations

To ensure proper collateralization, a liquidation system is put in place, where unhealthy positions can be liquidated.
A position is said to be healthy if the ratio of the borrowed value over collateral value is smaller than the liquidation loan-to-value (LLTV) of that market.
This leaves a safety buffer before the position can be insolvent, where the aforementioned ratio is above 1.
To ensure that liquidators have the time to interact with unhealthy positions, it is formally verified that this buffer is respected and that it leaves room for healthy liquidations to happen.
Notably, it is verified that in the absence of accrued interest, which is the case when creating a new position or when interacting multiple times in the same block, a position cannot be made unhealthy.

Let's define bad debt of a position as the amount borrowed when it is backed by no collateral.
Morpho Blue automatically realizes the bad debt when liquidating a position, by transferring it to the lenders.
In effect, this means that there is no bad debt on Morpho Blue, which is verified by the following invariant.

```solidity
invariant alwaysCollateralized(MorphoHarness.Id id, address borrower)
    borrowShares(id, borrower) != 0 => collateral(id, borrower) != 0;
```

More generally, this means that the result of liquidating a position multiple times eventually leads to a healthy position (possibly empty).

## Authorization

Morpho Blue also defines primitive authorization system, where users can authorize an account to fully manage their position.
This allows to rebuild more granular control of the position on top by authorizing an immutable contract with limited capabilities.
The authorization is verified to be sound in the sense that no user can modify the position of another user without proper authorization (except when liquidating).

Let's detail the rule that makes sure that the supply side stays consistent.

```solidity
rule userCannotLoseSupplyShares(env e, method f, calldataarg data)
filtered { f -> !f.isView }
{
    MorphoHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint sharesBefore = supplyShares(id, user);

    f(e, data);

    mathint sharesAfter = supplyShares(id, user);

    assert sharesAfter >= sharesBefore;
}
```

In the previous rule, an arbitrary function of Morpho Blue `f` is called with arbitrary `data`.
Shares of `user` on the market identified by `id` are recorded before and after this call.
In this way, it is checked that the supply shares are increasing when the caller of the function is neither the owner of those shares (`user != e.msg.sender`) nor authorized (`!isAuthorized(user, e.msg.sender)`).

## Other safety properties

### Enabled LLTV and IRM

Creating a market is permissionless on Morpho Blue, but some parameters should fall into the range of admitted values.
Notably, the LLTV value should be enabled beforehand.
The following rule checks that no market can ever exist with a LLTV that had not been previously approved.

```solidity
invariant onlyEnabledLltv(MorphoHarness.MarketParams marketParams)
    isCreated(libId(marketParams)) => isLltvEnabled(marketParams.lltv);
```

Similarly, the interest rate model (IRM) used for the market must have been previously whitelisted.

### Range of the fee

The governance can choose to set a fee to a given market.
Fees are guaranteed to never exceed 25% of the interest accrued, and this is verified by the following rule.

```solidity
invariant feeInRange(MorphoHarness.Id id)
    fee(id) <= maxFee();
```

### Sanity checks and input validation

The formal verification is also taking care of other sanity checks, some of which are needed properties to verify other rules.
For example, the following rule checks that the variable storing the last update time is no more than the current time.
This is a sanity check, but it is also useful to ensure that there will be no underflow when computing the time elapsed since the last update.

```solidity
rule noTimeTravel(method f, env e, calldataarg args)
filtered { f -> !f.isView }
{
    MorphoHarness.Id id;
    // Assume the property before the interaction.
    require lastUpdate(id) <= e.block.timestamp;
    f(e, args);
    assert lastUpdate(id) <= e.block.timestamp;
}
```

Additional rules are verified to ensure that the sanitization of inputs is done correctly.

```solidity
rule supplyInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    supply@withrevert(e, marketParams, assets, shares, onBehalf, data);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 => lastReverted;
}
```

The previous rule checks that the `supply` function reverts whenever the `onBehalf` parameter is the address zero, or when either both `assets` and `shares` are zero or both are non-zero.

## Liveness properties

On top of verifying that the protocol is secured, the verification also proves that it is usable.
Such properties are called liveness properties, and it is notably checked that the accounting is done when an interaction goes through.
As an example, the `withdrawChangesTokensAndShares` rule checks that calling the `withdraw` function successfully will decrease the shares of the concerned account and increase the balance of the receiver.

Other liveness properties are verified as well.
Notably, it's also verified that it is always possible to exit a position without concern for the oracle.
This is done through the verification of two rules: the `canRepayAll` rule and the `canWithdrawCollateralAll` rule.
The `canRepayAll` rule ensures that it is always possible to repay the full debt of a position, leaving the account without any outstanding debt.
The `canWithdrawCollateralAll` rule ensures that in the case where the account has no outstanding debt, then it is possible to withdraw the full collateral.

## Protection against common attack vectors

Other common and known attack vectors are verified to not be possible on the Morpho Blue protocol.

### Reentrancy

Reentrancy is a common attack vector that happens when a call to a contract allows, when in a temporary state, to call the same contract again.
The state of the contract usually refers to the storage variables, which can typically hold values that are meant to be used only after the full execution of the current function.
The Morpho Blue contract is verified to not be vulnerable to this kind of reentrancy attack thanks to the rule `reentrancySafe`.

### Extraction of value

The Morpho Blue protocol uses a conservative approach to handle arithmetic operations.
Rounding is done such that potential (small) errors are in favor of the protocol, which ensures that it is not possible to extract value from other users.

The rule `supplyWithdraw` handles the simple scenario of a supply followed by a withdraw, and has the following check.

```solidity
assert withdrawnAssets <= suppliedAssets;
```

The rule `withdrawAssetsAccounting` is more general and defines `ownedAssets` as the assets that the user owns, rounding in favor of the protocol.
This rule has the following check to ensure that no more than the owned assets can be withdrawn.

```solidity
assert withdrawnAssets <= ownedAssets;
```

# Folder and file structure

The [`certora/specs`](specs) folder contains the following files:

- [`AccrueInterest.spec`](specs/AccrueInterest.spec) checks that the main functions accrue interest at the start of the interaction.
  This is done by ensuring that accruing interest before calling the function does not change the outcome compared to just calling the function.
  View functions do not necessarily respect this property (for example, `totalSupplyShares`), and are filtered out.
- [`AssetsAccounting.spec`](specs/AssetsAccounting.spec) checks that when exiting a position the user cannot get more than what was owed.
  Similarly, when entering a position, the assets owned as a result are no greater than what was given.
- [`ConsistentState.spec`](specs/ConsistentState.spec) checks that the state (storage) of the Morpho contract is consistent.
  This includes checking that the accounting of the total amount and shares is correct, that markets are independent from each other, that only enabled IRMs and LLTVs can be used, and that users cannot have their position made worse by an unauthorized account.
- [`ExactMath.spec`](specs/ExactMath.spec) checks precise properties when taking into account exact multiplication and division.
  Notably, this file specifies that using supply and withdraw in the same block cannot yield more funds than at the start.
- [`ExchangeRate.spec`](specs/ExchangeRate.spec) checks that the exchange rate between shares and assets evolves predictably over time.
- [`Health.spec`](specs/Health.spec) checks properties about the health of the positions.
  Notably, debt positions always have some collateral thanks to the bad debt realization mechanism.
- [`LibSummary.spec`](specs/LibSummary.spec) checks the summarization of the library functions that are used in other specification files.
- [`LiquidateBuffer.spec`](specs/LiquidateBuffer.spec) checks that there is a buffer for liquidatable positions, before they are insolvent, such that liquidation leads to healthier position and cannot lead to bad debt.
- [`Liveness.spec`](specs/Liveness.spec) checks that main functions change the owner of funds and the amount of shares as expected, and that it's always possible to exit a position.
- [`Reentrancy.spec`](specs/Reentrancy.spec) checks that the contract is immune to a particular class of reentrancy issues.
- [`Reverts.spec`](specs/Reverts.spec) checks the condition for reverts and that inputs are correctly validated.
- [`StayHealthy.spec`](specs/Health.spec) checks that functions cannot render an account unhealthy.
- [`Transfer.spec`](specs/Transfer.spec) checks the summarization of the safe transfer library functions that are used in other specification files.

The [`certora/confs`](confs) folder contains a configuration file for each corresponding specification file.

The [`certora/helpers`](helpers) folder contains contracts that enable the verification of Morpho Blue.
Notably, this allows handling the fact that library functions should be called from a contract to be verified independently, and it allows defining needed getters.

The [`certora/dispatch`](dispatch) folder contains different contracts similar to the ones that are expected to be called from Morpho Blue.

# Getting started

## Compiling the harnesses

```bash
FOUNDRY_PROFILE=certora forge build
```

This compiles the harnesses in `certora/` against the Moolah source in `src/`, using the
repository's `remappings.txt`. solc 0.8.34 with `via_ir` is required (auto-managed by foundry).

## Running the prover

Install `certora-cli` package with `pip install certora-cli`.
To verify specification files, pass to `certoraRun` the corresponding configuration file in the [`certora/confs`](confs) folder.
It requires having set the `CERTORAKEY` environment variable to a valid Certora key.
You can also pass additional arguments, notably to verify a specific rule.
For example, at the root of the repository:

```
certoraRun certora/confs/ConsistentState.conf --rule borrowLessThanSupply
```

`certoraRun` picks up `remappings.txt`/`foundry.toml` from the project root to resolve the
Moolah import tree. The confs pin `solc-0.8.34` and `solc_via_ir: true` to match Moolah's
own build settings; make sure a `solc-0.8.34` binary is on PATH:

```bash
solc-select install 0.8.34
ln -sf ~/.solc-select/artifacts/solc-0.8.34/solc-0.8.34 ~/.local/bin/solc-0.8.34
```

To compile + typecheck a spec locally without running the cloud prover (no `CERTORAKEY`
needed), add `--compilation_steps_only`:

```bash
certoraRun certora/confs/ConsistentState.conf --compilation_steps_only
```

# Migration status

This is a **scaffolding migration**. The Solidity harnesses compile against Moolah, and **all
14 confs pass CVL compilation + typecheck locally** (`--compilation_steps_only`). Typecheck is
necessary but **not sufficient** — the rules have not been run through the prover, so none are
*verified* against Moolah yet (that needs `CERTORAKEY` and likely per-rule tuning).

CVL rules were re-pointed from Morpho Blue (`MorphoHarness` → `MoolahHarness`, `onMorpho*` →
`onMoolah*`). Getting them to typecheck also required dropping Morpho-only API:

- **`extSloads` removed.** Moolah has no `extSloads(bytes32[])`; the `NONDET DELETE` summary
  was removed from every spec that declared it.
- **`Reverts.spec` owner → role.** Moolah has no `owner()`/`setOwner` (it uses AccessControl).
  The `setOwner` rule was dropped and the `MANAGER`-gated setters (`enableIrm`, `enableLltv`,
  `setFee`, `setFeeRecipient`) re-expressed against `hasRole(MANAGER, sender)`, with their exact
  `<=>` revert conditions relaxed to one-directional `=>` (sound under Moolah's extra requires;
  the reverse direction needs prover confirmation).

## Proxy / upgradeability handling (done)

Because Moolah is a UUPS-upgradeable proxy contract, the upgrade/initialize machinery is
handled as follows (this is the standard Certora practice for upgradeable contracts):

- **Filtered out of generic invariants.** [`ProxyFilters.spec`](specs/ProxyFilters.spec) defines
  `isUpgradeOrInit(f)`, and every parametric (`method f`) rule excludes it via
  `filtered { f -> ... && !isUpgradeOrInit(f) }`. This stops the prover from havocing the whole
  state through `upgradeToAndCall`/`initialize` and reporting spurious counterexamples. The
  filter also covers the harness-only helpers below.
- **Verified by dedicated rules.** [`AccessControl.spec`](specs/AccessControl.spec) checks the
  authorization gates directly: `onlyAdminCanAuthorizeUpgrade`, `onlyPauserCanPause`,
  `onlyManagerCanUnpause`, `onlyManagerCanSetMinLoanValue`. The upgrade rule targets
  `_authorizeUpgrade` (via a harness wrapper) rather than `upgradeToAndCall`, whose `onlyProxy`
  guard reverts unconditionally on the directly-verified implementation and would otherwise make
  the rule vacuous.
- **Initialized starting state.** Moolah's constructor calls `_disableInitializers()`, so the
  real `initialize` can never run on the directly-verified implementation (the prover would start
  from an all-zero, role-less state). `MoolahHarness.setUpInitializedState(...)` reproduces the
  post-`initialize` state (roles + `minLoanValue`) so rules can assume a sane, initialized
  contract. (Alternative, heavier approach: a *munged* copy of `Moolah.sol` with
  `_disableInitializers()` removed so the real `initialize` is exercised — not used here.)

## Broker & provider exclusion (done)

Moolah lets a market be managed by a **LendingBroker** or fronted by a **Provider**. Both divert
the normal market flow and reach into external contracts, so both are **scoped out of
verification for now** (in [`ProxyFilters.spec`](specs/ProxyFilters.spec)), using the same
two-part pattern:

- **Broker.** Once `brokers[id]` is set, the broker replaces the supply/borrow/repay flow and
  the health check pulls the position's debt from the broker via an external call
  (`PriceLib._getBrokerTotalDebt`). `isBrokerFunction(f)` filters the broker-only entry points
  (`setMarketBroker`, `liquidateBrokerPosition`) out of parametric rules, and a `Sload` hook on
  `brokers[id]` assumes it is `0`, so `borrow`/`repay`/`_isHealthy`/`_getPrice` take the
  non-broker path and make no broker calls.
- **Provider.** Once `providers[id][token]` is set, a provider may act in place of the user in
  `borrow`/`withdraw`/`supplyCollateral` (authorization branches) and `liquidate` calls
  `IProvider(provider).liquidate(...)` (an external call). `isProviderFunction(f)` filters
  `setProvider` (which itself calls `IProvider(provider).TOKEN()`) out of parametric rules, and a
  `Sload` hook on `providers[id][token]` assumes it is `0`, so the provider branches take the
  standard authorization path and `liquidate` makes no provider call.

Both are **assumptions that scope verification to plain (non-broker, non-provider) markets** —
they do not prove anything about broker- or provider-managed markets.

## Still to do

- **Broker/provider markets themselves.** Verifying the broker- and provider-managed flows
  (rather than excluding them) is future work and needs dedicated specs.
- **Access control depth.** Beyond the gates above, rules inherited from Morpho Blue that assume
  a single `owner` model should be revisited against Moolah's role model (`DEFAULT_ADMIN_ROLE`,
  `MANAGER`, `PAUSER`).
- **Oracle / `PriceLib` price model** and the **liquidation whitelist** are new relative to
  Morpho Blue and are not covered by the migrated specs.
- **Per-rule review.** Each spec should be re-checked against Moolah's actual function set and
  semantics; method blocks may reference functions whose signatures or behavior diverged.

# Running the prover from a PR (CI)

Verification runs on GitHub-hosted runners (free for public repos, 4 vCPU /
16 GB each) using the open-source Certora Prover image
(`ghcr.io/lista-dao/certora-local`) — no CERTORAKEY, no Certora cloud.
The workflow is `.github/workflows/certora.yml`.

## Usage

Comment on any PR (requires write access to the repo):

```
/certora ConsistentState            # one conf
/certora ConsistentState Health     # several confs
/certora all                        # every conf in certora/confs/
```

The bot reacts with 👀, replies with a link to the run, and when done posts a
result table (per conf: ✅/❌, verified/violated rule counts, violated rule
names). Full HTML reports (`FinalResults.html`, one row per rule/invariant
with counterexample call traces) are attached to the run as one
`certora-<conf>-*` artifact per conf. Any violation turns the check red.

Manual runs: Actions → certora → *Run workflow* (works on any branch that
contains the workflow file; the comment command only works once the workflow
is on `master`).

Confs fan out as a matrix — each conf gets its own runner and they all run in
parallel, so wall-clock time is the slowest conf, not the sum. Expect roughly
1–3 h for heavy confs (`ConsistentState` ≈ 73 min on a comparable 4-core box);
the hosted-runner hard limit is 6 h per conf — if a conf hits it (e.g.
`StayHealthy`-class specs), split it with a `"rule": [...]` filter.

Note: the CI localizes the cloud confs on the fly (drops `server`, renames
`solc-X.Y.Z` to the image's `solcX.Y.Z`, adds a JVM heap) — the files in
`certora/confs/` stay in cloud format and still work with `certoraRun` +
CERTORAKEY if needed.

## Operations

- Hosted runners are free only while this repo is public; if it ever goes
  private, minutes are billed (and drop to 2-core machines) — revisit the
  runner strategy then.
- The workflow pulls `ghcr.io/lista-dao/certora-local:latest` with the
  workflow's `GITHUB_TOKEN`; the GHCR package must stay public or keep this
  repo granted read access in its package settings.
- Update the prover image by rebuilding it (see the certora-docker project)
  and pushing to `ghcr.io/lista-dao/certora-local:latest`; jobs pull on every
  run.
- Memory/heap knobs live in the workflow's `env` block (`CONTAINER_MEM`,
  `JAVA_HEAP`), sized for the 16 GB hosted runners.
- If a PR has merge conflicts, the `refs/pull/N/merge` checkout fails —
  resolve conflicts first, then re-comment.

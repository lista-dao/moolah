# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Core Rules

- Always read files before editing them. Never attempt to edit a file you haven't read in the current session.
- Before making changes, present a brief plan. Do not copy files unnecessarily or make excessive multi-file changes without confirmation.

## Commands

```bash
# Build
forge build

# Run all tests
forge test -vvv

# Run tests for a specific contract
forge test --mc <ContractName> -vv

# Run a single test
forge test --mc <ContractName> --mt <testFunctionName> -vvvv

# Lint check / fix
npm run check   # prettier --check
npm run fix     # prettier --write

# Deploy a script
forge script <script_path> --rpc-url <rpc_url> --private-key <pk> --broadcast --verify -vvv --via-ir
```

**Required env vars for fork tests:**
- `BSC_RPC` — BSC mainnet RPC (used by most fork tests)
- `BSC_TESTNET_RPC_URL`, `SEPOLIA_RPC_URL`, `ETHEREUM_RPC_URL` — secondary forks

## Architecture

This is a BSC lending protocol. The main contract is **Moolah** (`src/moolah/Moolah.sol`) — a Morpho Blue–style isolated lending market. Markets are defined by `MarketParams` (loanToken, collateralToken, oracle, irm, lltv) and identified by a `bytes32` `Id` derived from `MarketParamsLib.id()`.

**Key modules:**

- `src/moolah/` — Core protocol. `Moolah.sol` manages isolated lending markets. Access control uses `MANAGER`, `OPERATOR`, and `PAUSER` roles. `createMarket` requires `OPERATOR` role (or no OPERATOR set). `borrow` requires the borrower to call `setAuthorization(spender, true)` first.

- `src/moolah-vault/` — `MoolahVault.sol`, a curated multi-market vault that allocates deposited liquidity across Moolah markets.

- `src/broker/` — `LendingBroker.sol` wraps Moolah for structured borrow positions (single collateral/loan pair per broker). `CreditBroker.sol` handles credit-based borrowing with interest relaying.

- `src/provider/` — Providers sit between users and Moolah markets, abstracting collateral management:
  - `BNBProvider.sol` / `ETHProvider.sol` — wrap native BNB/ETH into WBNB/WETH on supply and unwrap on withdraw.
  - `SlisBNBProvider.sol` — accepts slisBNB as collateral, tracks per-user deposits across multiple markets (`userMarketDeposit`, `userTotalDeposit`), and mints/burns `clisXXX` LP tokens proportional to the user's BNB-denominated value (via `StakeManager.convertSnBnbToBnb`). A portion of LP is minted to MPC wallets as protocol reserve (`userLpRate`, `mpcWallets`). Supports a pluggable `slisBNBxMinter`: when set, the legacy LP logic is phased out and all slisBNBx minting is delegated to `SlisBNBxMinter` via `ISlisBNBxMinter.rebalance(account)`. Delegation of LP tokens to another address is supported via `delegateAllTo`.
  - `SmartProvider.sol` — accepts a `StableSwapLPCollateral` token as Moolah collateral. Users can supply raw token pairs to the stable swap pool (receiving LP) or supply existing LP directly; withdraw variants include proportional, imbalanced, and single-coin exits. Also supports the pluggable `slisBNBxMinter`: when set, `_syncPosition` calls `ISlisBNBxMinter.rebalance(account)` after every position change so users earn slisBNBx on top of swap fees. Implements `IOracle` — prices the LP token as `min(price0, price1) × virtual_price`.
  - `V3Provider.sol` — manages a single Uniswap/PancakeSwap V3 concentrated liquidity position; issues ERC20 shares as Moolah collateral. See `docs/V3Provider.md` for full details.

- `src/utils/PositionMigrator.sol` — Migrates CDP positions (from `lista-dao-contracts` Interaction contract) into Moolah markets via flash loans.

- `src/utils/SlisBNBxMinter.sol` — Central hub for minting slisBNBx (Binance Launchpool participation token) to users who deposit collateral through registered provider modules. Each module (`SlisBNBProvider`, `SmartProvider`, etc.) calls `ISlisBNBxMinter.rebalance(account)` after every position change; the minter pulls the user's BNB-denominated balance via `ISlisBNBxModule.getUserBalanceInBnb`, applies a per-module `discount` and `feeRate`, then mints/burns slisBNBx to the user's delegatee and to MPC fee wallets. Key design points:
  - **Pluggable modules**: any provider can register as a module via `addModule(address, ModuleConfig)`. Disabling sets `discount = 100%`.
  - **Delegation**: users can redirect their slisBNBx to another address via `delegateAllTo`; modules sync delegatee changes via `syncDelegatee`.
  - **MPC fee wallets**: protocol fee portion of slisBNBx is distributed across capped MPC wallets; minting fills from first wallet, burning drains from last.
  - **Transition from legacy LP**: `SlisBNBProvider` burns all legacy `clisXXX` LP before handing off to the minter on the first sync after `slisBNBxMinter` is set.

- `src/oracle/` — `OracleAdaptor.sol` wraps Chainlink/custom feeds into Moolah's `peek(token)` interface.

- `src/dex/` — Stable swap pools used for solvBTC/BTCB and similar pairs; LP tokens can be used as collateral via `StableSwapLPCollateral.sol`.

- `src/interest-rate-model/` — `InterestRateModel.sol` (standard) and fixed-rate IRM. The alphaIrm address `0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6` is the production IRM for most lisUSD markets.

**External dependencies (via `lib/`):**
- `lista-dao-contracts.git` — CDP Interaction contract, SlisBNBProvider CDP, HelioProviderV2. These are upgraded in fork tests before migration tests run.
- `openzeppelin-contracts-upgradeable` — All upgradeable contracts use UUPS pattern.
- `solady` — Used for `SafeTransferLib`.

**Key production addresses (BSC mainnet):**
- Moolah: `0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C`
- multiOracle: `0xf3afD82A4071f272F403dC176916141f44E6c750`
- Timelock (admin): `0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253`
- Moolah market operator: `0xd7e38800201D6a42C408Bf79d8723740C4E7f631`

## Solidity Workflow

After any Solidity code change, run `forge build` before proceeding. If compilation fails, fix it immediately before making further changes. Set `--force false` (or omit `--force`) to use the incremental build cache — only use `forge build --force` when debugging cache-related issues.

## Testing

When writing or fixing Foundry tests, pay close attention to: tick spacing alignment, vm.prank consumption order, oracle mock setup, and minimum liquidity requirements. Run `forge test --match-test <testName>` after each test change.

## Fork Test Patterns

Fork tests call `vm.createSelectFork(vm.envString("BSC_RPC"), <block>)` in `setUp`. When testing `PositionMigrator`, three contracts must be upgraded in setUp before the migration runs (via `IProxyAdmin.upgrade` / `IUUPSUpgradeable.upgradeTo`): `Interaction`, `HelioProviderV2`, and `SlisBNBProvider`. The `Interaction.migrator()` return value is `vm.mockCall`-ed to return the migrator address.

To create a fresh Moolah market in a test, the test contract needs `OPERATOR` role — grant it via `IAccessControl(address(MOOLAH)).grantRole(keccak256("OPERATOR"), address(this))` while pranked as the timelock admin (who holds `DEFAULT_ADMIN_ROLE`).

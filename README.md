# Moolah

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://book.getfoundry.sh/)

**Moolah** is a decentralized lending protocol developed by [Lista DAO](https://lista.org). Built on top of [Morpho Blue](https://morpho.org), it enables permissionless lending and borrowing with isolated markets, customizable risk parameters, and efficient capital utilization.

## Features

- **Isolated Lending Markets** - Each market has its own collateral and loan asset pair with independent risk parameters
- **Customizable LLTVs** - Flexible Loan-to-Value ratios for different asset pairs
- **Vault System** - ERC4626-compliant vaults for passive lending strategies
- **Multi-chain Support** - Deployed on BNB Chain and Ethereum
- **Interest Rate Models** - Configurable interest rate strategies including fixed-rate options
- **Smart Collateral** - Advanced collateral management with provider integrations
- **Liquidation System** - Efficient liquidation mechanism with customizable parameters

## Architecture

```
src/
├── moolah/              # Core lending protocol
├── moolah-vault/        # ERC4626 vault implementations
├── interest-rate-model/ # Interest rate strategies
├── liquidator/          # Liquidation logic
├── oracle/              # Price oracle integrations
├── provider/            # Collateral provider integrations
├── vault-allocator/     # Vault allocation strategies
├── broker/              # Broker integrations
├── revenue/             # Fee distribution
└── timelock/            # Governance timelock
```

## Security

Moolah has been audited by multiple security firms. All audit reports are available in the [`docs/audits/`](docs/audits/) directory:

- **Blocksec** - Core lending protocol audit
- **Bailsec** - Multiple audits covering core protocol, providers, and smart collateral
- **OpenZeppelin** - Smart collateral audit
- **Cantina** - Fixed term and rate audit

## Documentation

- [Foundry Book](https://book.getfoundry.sh/) - Development framework documentation
- [Lista DAO](https://lista.org) - Protocol documentation

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) (v18+)
- [Yarn](https://yarnpkg.com/)

### Clone

```shell
# Clone the repository with submodules
git clone --recursive git@github.com:lista-dao/moolah.git

# If cloned without --recursive, update submodules
git submodule update --init --recursive
```

### Install Dependencies

```shell
yarn install
```

### Build

```shell
forge build
```

### Test

```shell
# Run all tests
forge test

# Run specific test contract
forge test --match-contract SafeGuardTest -vvv

# Run specific test function
forge test --match-contract BuybackTest --match-test "testExecutorOfNoneOwner" -vvv
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

## Deployment

### Deploy

```shell
forge script <path_to_script> --rpc-url <your_rpc_url> --private-key <your_private_key> --etherscan-api-key <api-key> --broadcast --verify -vvv --via-ir
```

### Verify Contract

```shell
forge verify-contract --rpc-url <your_rpc_url> --chain-id <chain-id> <address> <contract-name> --api-key <api-key>
```

## Local Development

### Start Local Node

```shell
anvil
```

### Interact with Contracts

```shell
# Call a view function
cast call <contract_address> <method_name> <method_args>

# Send a transaction
cast send <contract_address> <method_name> <method_args> --private-key <private_key> --rpc-url <rpc_url>
```

## Contributing

Contributions are welcome! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- [Morpho Labs](https://morpho.org) - Core lending protocol design inspiration
- [OpenZeppelin](https://openzeppelin.com) - Secure smart contract libraries

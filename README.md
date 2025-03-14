## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Clone
```shell
# clone the repository
git clone --recursive git@github.com:lista-dao/moolah.git

# update submodules if cloned without --recursive
git submodule update --init --recursive
```

### Install
```shell
yarn install
```


### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
#### test a specific contract
```shell
forge test --match-contract SafeGuardTest -vvv
forge test --match-contract BuybackTest --match-test "testExecutorOfNoneOwner" -vvv
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script <path_to_script> --rpc-url <your_rpc_url> --private-key <your_private_key> --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv --via-ir
# deploy SafeGuard Contract
$ forge script script/safe/SafeGuard.s.sol:SafeGuardScript --rpc-url <your_rpc_url> --private-key <your_private_key> --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
```

### Verify

```shell
$ forge verify-contract --rpc-url <your_rpc_url> --chain-id <chain-id> <address> <contract-name> --api-key <bscscan-api-key>
```

### Cast

```shell
$ cast <subcommand>
$ cast call <contract_address> <method_name> <method_args>
$ cast send <contract_address> <method_name> <method_args> --private-key <private_key>
# demo
$ cast send <contract_address> "addExecutor(address)" <...parameters> --rpc-url $RPC --private-key $PRIVATE_KEY 
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

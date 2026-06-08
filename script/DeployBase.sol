// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

/// @notice Base contract for deploy scripts. Selects the deployer private key
///         based on the target chain id so scripts work on any chain without edits.
abstract contract DeployBase is Script {
  function _deployerKey() internal view returns (uint256) {
    if (block.chainid == 56) return vm.envUint("PRIVATE_KEY"); // BSC mainnet
    if (block.chainid == 97) return vm.envUint("PRIVATE_KEY_TESTNET"); // BSC testnet
    if (block.chainid == 11155111) return vm.envUint("PRIVATE_KEY_TESTNET"); // Sepolia
    return vm.envUint("PRIVATE_KEY"); // Ethereum mainnet & others
  }
}

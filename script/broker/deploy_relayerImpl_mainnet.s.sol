// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { BrokerInterestRelayer } from "../../src/broker/BrokerInterestRelayer.sol";

/// @notice Deploy the NEW shared BrokerInterestRelayer implementation on BSC mainnet.
///
/// Run:
///   forge script script/broker/deploy_relayerImpl_mainnet.s.sol \
///     --rpc-url $BSC_RPC --private-key $PK --broadcast --verify --via-ir -vvv
contract DeployRelayerImpl is Script {
  /// @dev ERC-1967 implementation slot = keccak256("eip1967.proxy.implementation") - 1.
  ///      A valid UUPS impl's proxiableUUID() must return exactly this, or the UUPS proxy's
  ///      upgradeToAndCall reverts with UUPSUnsupportedProxiableUUID. (bytes32 — not an address,
  ///      so no EIP-55 checksum applies.)
  bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  function run() public {
    require(block.chainid == 56, "not BSC mainnet");
    vm.startBroadcast();
    BrokerInterestRelayer impl = new BrokerInterestRelayer();
    vm.stopBroadcast();

    // sanity: confirm the deployed impl is a valid UUPS implementation (correct proxiableUUID),
    // i.e. the 5 relayer UUPS proxies will accept it in upgradeToAndCall.
    bytes32 uuid = impl.proxiableUUID();
    require(uuid == ERC1967_IMPL_SLOT, "impl: not UUPS / wrong proxiableUUID");

    console.log("NEW BrokerInterestRelayer impl:", address(impl));
    console.log("  proxiableUUID OK (== ERC-1967 impl slot):");
    console.logBytes32(uuid); // 0x360894a1...382bbc
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

/// @notice Deploy the shared LendingBroker implementation on BSC mainnet.
/// Constants are baked in (no env needed). WBNB is the real mainnet WBNB so native-BNB support
/// is preserved for every broker proxy — all mainnet brokers carry this same WBNB immutable.
///   forge script script/broker/deploy_brokerImpl_mainnet.s.sol \
///     --rpc-url $BSC_RPC_URL --broadcast --verify --via-ir -vvv
contract DeployLendingBrokerImplMainnet is DeployBase {
  address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  function run() public {
    require(block.chainid == 56, "not BSC mainnet");

    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer:", vm.addr(deployerPrivateKey));
    console.log("MOOLAH:  ", MOOLAH);
    console.log("WBNB:    ", WBNB);

    vm.startBroadcast(deployerPrivateKey);
    LendingBroker impl = new LendingBroker(MOOLAH, WBNB);
    vm.stopBroadcast();

    console.log("LendingBroker implementation:", address(impl));
  }
}

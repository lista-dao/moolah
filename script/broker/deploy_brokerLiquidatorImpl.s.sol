// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { BrokerLiquidator } from "../../src/liquidator/BrokerLiquidator.sol";

contract DeployBrokerLiquidatorImpl is DeployBase {
  // MOOLAH is immutable in BrokerLiquidator, so the new implementation must be
  // constructed with the same Moolah the target proxy already uses.
  address moolah;

  // BSC mainnet Moolah
  address constant MOOLAH_BSC = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  // BSC testnet Moolah (matches BrokerLiquidator proxy 0xeAe8EaB31E7299Cc4c7C6F08f3C1AA8eF08dC175)
  address constant MOOLAH_BSC_TESTNET = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;

  function setUp() public {
    if (block.chainid == 56) {
      moolah = MOOLAH_BSC;
    } else if (block.chainid == 97) {
      moolah = MOOLAH_BSC_TESTNET;
    } else {
      moolah = vm.envAddress("MOOLAH");
    }
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    console.log("Moolah:   ", moolah);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy BrokerLiquidator implementation only (for upgrading an existing proxy)
    BrokerLiquidator impl = new BrokerLiquidator(moolah);
    console.log("BrokerLiquidator implementation: ", address(impl));

    vm.stopBroadcast();
  }
}

pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";

import "./SCAddress.sol";

// Step 1 — create the two new StableSwap pools (USD1/USDT, lisUSD/USDT).
// Params match the live USDC/USDT smart pool: fee 0.1bp (1e5), admin_fee 20% (2e9), priceDiff 5%.
// A per PRD: USD1/USDT = 10000, lisUSD/USDT = 5000. Requires deployer DEPLOYER role on the factory.
contract StableSwapPairDeploy is DeployBase {
  StableSwapFactory factory = StableSwapFactory(SS_FACTORY);

  uint256 constant FEE = 100000; // 0.1bp = fee / 1e10
  uint256 constant ADMIN_FEE = 2e9; // 20% of swap fee to admin
  uint256 constant PRICE_DIFF = 5e16; // 5%

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    createPair(USD1, USDT, "USD1 & USDT-LP", 10000, deployer);
    createPair(LISUSD, USDT, "lisUSD & USDT-LP", 5000, deployer);

    vm.stopBroadcast();
  }

  function createPair(address t0, address t1, string memory name, uint256 _A, address deployer) internal {
    (address _lp, address _pool) = factory.createSwapPair(
      t0,
      t1,
      name,
      name,
      _A,
      FEE,
      ADMIN_FEE,
      deployer, // admin (transferred in step 4)
      deployer, // manager
      deployer, // pauser
      RESILIENT_ORACLE
    );
    console.log("Created pool: ", name);
    console.log("  LP token: ", _lp);
    console.log("  Pool:     ", _pool);

    StableSwapPool(_pool).changePriceDiffThreshold(PRICE_DIFF, PRICE_DIFF);
    console.log("  priceDiffThreshold set to 5%");
  }
}

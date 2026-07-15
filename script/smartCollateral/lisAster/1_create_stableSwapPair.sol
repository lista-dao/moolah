pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";

import "./LisAsterAddress.sol";

// Step 1: create the lisAster <> Aster stable swap pool and disable the oracle
//         price-diff check on it.
//
// forge script script/smartCollateral/lisAster/1_create_stableSwapPair.sol \
//   --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast -vvv --via-ir
contract CreateLisAsterAsterPair is DeployBase {
  StableSwapFactory factory = StableSwapFactory(SS_FACTORY);

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    require(factory.lpImpl() != address(0), "LP impl not set");
    require(factory.swapImpl() != address(0), "Swap impl not set");

    // Amplification coefficient (requested): A = 20
    uint256 _A = 20;
    uint256 _fee = 25000000; // 0.25% (25 bp) swap fee
    uint256 _adminFee = 2e9; // 20% of swap fee goes to admin
    string memory name = "lisAster & ASTER-LP";

    vm.startBroadcast(deployerPrivateKey);

    (address _lp, address _pool) = factory.createSwapPair(
      LISASTER,
      ASTER,
      name,
      name,
      _A,
      _fee,
      _adminFee,
      deployer, // admin
      deployer, // manager
      deployer, // pauser
      RESILIENT_ORACLE
    );

    console.log("Created pool: ", name);
    console.log("StableSwapPool LP token: ", _lp);
    console.log("StableSwapPool: ", _pool);

    // Disable oracle price-diff check (requested).
    // Deployer holds MANAGER on the freshly created pool, so this call succeeds here.
    StableSwapPool(_pool).setSkipPriceDiff(true);
    console.log("skipPriceDiff enabled (priceDiffCheck disabled)");

    vm.stopBroadcast();

    console.log("NEXT: set DEX_LISASTER_ASTER and LP_LISASTER_ASTER in LisAsterAddress.sol");
  }
}

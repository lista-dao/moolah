pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";

import "./SCAddress.sol";

contract StableSwapPairDeploy is Script {
  StableSwapFactory factory = StableSwapFactory(SS_FACTORY);

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    //createPairBNB(deployer);
    createPairBTCB(deployer);
  }

  function createPairBNB(address deployer) public {
    require(factory.lpImpl() != address(0), "LP impl not set");
    require(factory.swapImpl() != address(0), "Swap impl not set");

    // Create slisBnb <> Bnb pool
    uint _A = 100;
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 1e9; // 10% swap fee goes to admin

    (address _lp, address _pool) = factory.createSwapPair(
      SLISBNB,
      BNB_ADDRESS,
      "slisBNB & BNB-LP",
      "slisBNB & BNB-LP",
      _A,
      _fee,
      _adminFee,
      deployer, // admin
      deployer, // manager
      deployer, // pauser
      RESILIENT_ORACLE
    );

    console.log("Created slisBNB <> BNB pool");
    console.log("StableSwapPool LP token: ", _lp);
    console.log("StableSwapPool: ", _pool);

    // set price diff limit to 5%
    StableSwapPool(_pool).changePriceDiffThreshold(5e16, 5e16);
    console.log("Set price diff limit to 5%");
  }

  // create solvBTC / BTCB pool
  function createPairBTCB(address deployer) public {
    require(factory.lpImpl() != address(0), "LP impl not set");
    require(factory.swapImpl() != address(0), "Swap impl not set");

    uint _A = 50;
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 0;

    (address _lp, address _pool) = factory.createSwapPair(
      SOLVBTC,
      BTCB,
      "BTCB & solvBTC-LP",
      "BTCB & solvBTC-LP",
      _A,
      _fee,
      _adminFee,
      deployer, // admin
      deployer, // manager
      deployer, // pauser
      RESILIENT_ORACLE
    );

    console.log("Created solvBTC <> BTCB pool");
    console.log("StableSwapPool LP token: ", _lp);
    console.log("StableSwapPool: ", _pool);
  }
}

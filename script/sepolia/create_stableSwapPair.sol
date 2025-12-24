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
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    createPair_sepolia(deployer);
  }

  function createPair_sepolia(address deployer) public {
    // Create $U & USDT
    uint _A = 5000;
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 2e9; // 20% swap fee goes to admin
    uint _priceDiffThreshold = 5e16; // 5%
    string memory name = "USD1 & USDT-LP";

    (address _lp, address _pool) = factory.createSwapPair(
      USD1,
      USDT,
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

    // set price diff limit to 5%
    StableSwapPool(_pool).changePriceDiffThreshold(5e16, 5e16);
    console.log("Set price diff limit to 5%");

    // set gas to 230,000
    StableSwapPool(_pool).set_bnb_gas(23000);
    console.log("Set native gas to 23,000");
  }
}

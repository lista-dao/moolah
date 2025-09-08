pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";

contract StableSwapFactoryDeploy is Script {
  StableSwapFactory factory = StableSwapFactory(0x75FeA788F632586138DBc4D40c5AB2350Ad5FA40);
  address lpImpl = 0x1db4DC1da433E3834ccb8fd585288D268381f44e;
  address poolImpl = 0x41c948FE3dC9Dd915d5c19a6135C7F454Af75e97;
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    deploy_qa(deployer);
  }

  function deploy_qa(address deployer) public {
    //    address factory = deployFactory(deployer);
    //    (address lpImpl, address poolImpl) = deployImpls();

    factory.setImpls(lpImpl, poolImpl);

    console.log("Set impls in Factory");

    // Create slisBnb <> Bnb pool
    address slisBnb = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
    address bnb = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint _A = 1000;
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 5e9; // 50% swap fee goes to admin
    address oracle = 0x79e9675cDe605Ef9965AbCE185C5FD08d0DE16B1;

    (address _lp, address _pool) = factory.createSwapPair(
      slisBnb,
      bnb,
      "StableSwap LP Token",
      "ss-LP",
      _A,
      _fee,
      _adminFee,
      deployer,
      deployer,
      deployer,
      oracle
    );

    console.log("Created slisBNB <> BNB pool");
    console.log("StableSwapPool LP token: ", _lp);
    console.log("StableSwapPool: ", _pool);
  }

  function deployFactory(address admin) public returns (address) {
    // Deploy Factory
    StableSwapFactory factory = new StableSwapFactory();
    ERC1967Proxy proxy = new ERC1967Proxy(address(factory), abi.encodeWithSelector(factory.initialize.selector, admin));
    factory = StableSwapFactory(address(proxy));
    console.log("StableSwapFactory Proxy deployed to: ", address(proxy));
  }

  function deployImpls(address factory) public returns (address, address) {
    StableSwapLP lpImpl = new StableSwapLP();
    console.log("StableSwapLP impl deployed to: ", address(lpImpl));
    StableSwapPool poolImpl = new StableSwapPool(factory);
    console.log("StableSwapPool impl deployed to: ", address(poolImpl));
    return (address(lpImpl), address(poolImpl));
  }
}

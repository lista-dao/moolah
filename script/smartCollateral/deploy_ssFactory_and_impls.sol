pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapFactory } from "src/dex/StableSwapFactory.sol";
import { StableSwapLP } from "src/dex/StableSwapLP.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { StableSwapPool } from "src/dex/StableSwapPool.sol";

contract StableSwapFactoryDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    address factoryAddr = deployFactory(deployer, deployer);

    (address lpImpl, address poolImpl) = deployImpls(factoryAddr);

    StableSwapFactory factory = StableSwapFactory(factoryAddr);

    factory.setLpImpl(lpImpl);
    factory.setSwapImpl(poolImpl);

    console.log("Set impls in Factory");
  }

  function deployFactory(address admin, address deployer) public returns (address) {
    address[] memory deployers = new address[](1);
    deployers[0] = deployer;
    // Deploy Factory
    StableSwapFactory factory = new StableSwapFactory();
    console.log("StableSwapFactory impl deployed to: ", address(factory));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(factory),
      abi.encodeWithSelector(factory.initialize.selector, admin, deployers)
    );
    console.log("StableSwapFactory Proxy deployed to: ", address(proxy));
    return address(proxy);
  }

  function deployImpls(address factory) public returns (address, address) {
    StableSwapLP lpImpl = new StableSwapLP();
    console.log("StableSwapLP impl deployed to: ", address(lpImpl));
    StableSwapPool poolImpl = new StableSwapPool(factory);
    console.log("StableSwapPool impl deployed to: ", address(poolImpl));
    return (address(lpImpl), address(poolImpl));
  }
}

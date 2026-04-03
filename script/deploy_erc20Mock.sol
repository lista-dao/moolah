pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "./DeployBase.sol";

import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

contract InterestRateModelDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy erc20 mock
    ERC20Mock mock = new ERC20Mock();
    mock.setDecimals(18);
    mock.setBalance(deployer, 1e18);
    mock.setName("pt-clisBNB-25apr");
    mock.setSymbol("pt-clisBNB-25apr");
    console.log("ERC20Mock deploy to: ", address(mock));

    vm.stopBroadcast();
  }
}

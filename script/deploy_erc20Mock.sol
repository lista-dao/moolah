pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

contract InterestRateModelDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
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

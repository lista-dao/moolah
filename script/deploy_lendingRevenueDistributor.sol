pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { LendingRevenueDistributor } from "../src/revenue/LendingRevenueDistributor.sol";

contract LendingRevenueDistributorDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    address admin = vm.envAddress("ADMIN");
    address manager = vm.envAddress("MANAGER");
    address bot = 0x44CA74923aA2036697a3fA7463CD0BA68AB7F677;
    address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
    console.log("Admin: ", admin);
    console.log("Manager: ", manager);
    console.log("Bot: ", bot);
    console.log("Pauser: ", pauser);

    address revenueReceiver = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
    address riskFundReceiver = 0x618579671f4B5a96Ff6Ac3Fb66224df39Ce9d325;
    console.log("Revenue Receiver: ", revenueReceiver);
    console.log("Risk Fund Receiver: ", riskFundReceiver);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    LendingRevenueDistributor impl = new LendingRevenueDistributor();
    console.log("LendingRevenueDistributor implementation: ", address(impl));

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, bot, pauser, revenueReceiver, riskFundReceiver)
    );
    console.log("LendingRevenueDistributor proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}

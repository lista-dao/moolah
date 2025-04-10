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
    address bot = vm.envAddress("BOT");
    address pauser = vm.envAddress("PAUSER");
    console.log("Admin: ", admin);
    console.log("Manager: ", manager);
    console.log("Bot: ", bot);
    console.log("Pauser: ", pauser);

    address revenueReceiver = vm.envAddress("REVENUE_RECEIVER");
    address riskFundReceiver = vm.envAddress("RISK_FUND_RECEIVER");
    console.log("Revenue Receiver: ", revenueReceiver);
    console.log("Risk Fund Receiver: ", riskFundReceiver);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    LendingRevenueDistributor impl = new LendingRevenueDistributor();
    console.log("LendingRevenueDistributor implementation: ", address(impl));

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager, bot, pauser, revenueReceiver, riskFundReceiver)
    );
    console.log("LendingRevenueDistributor proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}
